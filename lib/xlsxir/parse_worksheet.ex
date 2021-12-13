defmodule Xlsxir.ParseWorksheet do
  alias Xlsxir.{ConvertDate, ConvertDateTime, SaxError}
  import Xlsxir.ConvertDate, only: [convert_char_number: 1]
  require Logger

  @moduledoc """
  Holds the SAX event instructions for parsing worksheet data via `Xlsxir.SaxParser.parse/2`
  """

  defstruct row: [],
            cell_ref: "",
            data_type: "",
            num_style: "",
            value: "",
            value_type: nil,
            max_rows: nil,
            tid: nil

  @doc """
  Sax event utilized by `Xlsxir.SaxParser.parse/2`. Takes a pattern and the current state of a struct and recursivly parses the
  worksheet XML file, ultimately saving a list of cell references and their assocated values to the ETS process.

  ## Parameters

  - `arg1` - the XML pattern of the event to match upon
  - `state` - the state of the `%Xlsxir.ParseWorksheet{}` struct which temporarily holds applicable data of the current row being parsed

  ## Example
  Each entry in the list created consists of a list containing a cell reference string and the associated value (i.e. `[["A1", "string one"], ...]`).
  """
  def sax_event_handler(
        :startDocument,
        _state,
        %{max_rows: max_rows, workbook: workbook_tid},
        xml_name
      ) do
    tid = GenServer.call(Xlsxir.StateManager, :new_table)

    "sheet" <> remained = xml_name
    {sheet_id, _} = Integer.parse(remained)

    worksheet_name =
      List.foldl(:ets.lookup(workbook_tid, sheet_id), nil, fn value, _ ->
        case value do
          {_, worksheet_name} -> worksheet_name
          _ -> nil
        end
      end)

    # [{_, worksheet_name} | _] = :ets.lookup(workbook_tid, rid)

    :ets.insert(tid, {:info, :worksheet_name, worksheet_name})

    %__MODULE__{tid: tid, max_rows: max_rows}
  end

  def sax_event_handler(
        {:startElement, _, 'row', _, _},
        %__MODULE__{tid: tid, max_rows: max_rows},
        _excel,
        _
      ) do
    %__MODULE__{tid: tid, max_rows: max_rows}
  end

  def sax_event_handler({:startElement, _, 'c', _, xml_attr}, state, %{styles: styles_tid}, _) do
    a =
      Enum.reduce(xml_attr, %{}, fn attr, acc ->
        case attr do
          {:attribute, 's', _, _, style} ->
            Map.put(acc, "s", find_styles(styles_tid, List.to_integer(style)))
          {:attribute, key, _, _, ref} ->
            Map.put(acc, to_string(key), ref)
        end
      end)

    {cell_ref, num_style, data_type} = {a["r"], a["s"], a["t"]}

    %{state | cell_ref: cell_ref, num_style: num_style, data_type: data_type}
  end

  def sax_event_handler({:startElement, _, 'f', _, _}, state, _, _) do
    %{state | value_type: :formula}
  end

  def sax_event_handler({:startElement, _, el, _, _}, state, _, _) when el in ['v', 't'] do
    %{state | value_type: :value}
  end

  def sax_event_handler({:endElement, _, el, _, _}, state, _, _) when el in ['f', 'v', 't'] do
    %{state | value_type: nil}
  end

  def sax_event_handler({:characters, value}, state, _, _) do
    case state do
      nil -> nil
      %{value_type: :value} -> %{state | value: value}
      _ -> state
    end
  end

  def sax_event_handler({:endElement, _, 'c', _}, %__MODULE__{row: row} = state, excel, _) do
    cell_value = format_cell_value(excel, [state.data_type, state.num_style, state.value])
    new_cell = [to_string(state.cell_ref), cell_value]

    %{
      state
      | row: [new_cell | row],
        cell_ref: "",
        data_type: "",
        num_style: "",
        value: ""
    }
  end

  def sax_event_handler(
        {:endElement, _, 'row', _},
        %__MODULE__{tid: tid, max_rows: max_rows} = state,
        _excel,
        _
      ) do
    unless Enum.empty?(state.row) do
      [[row]] = ~r/\d+/ |> Regex.scan(state.row |> List.first() |> List.first())
      row = row |> String.to_integer()
      value = state.row |> Enum.reverse()

      :ets.insert(tid, {row, value})
      if !is_nil(max_rows) and row == max_rows, do: raise(SaxError, state: state)
    end

    state
  end

  def sax_event_handler(_, state, _, _), do: state

  defp format_cell_value(%{shared_strings: strings_tid}, list) do
    case list do
      # Cell with no value attribute
      [_, _, nil] -> nil
      # Empty cell with assigned attribute
      [_, _, ""] -> nil
      # Type error
      ['e', _, e] -> List.to_string(e)
      # Type string
      ['s', _, i] -> find_string(strings_tid, List.to_integer(i))
      # Type number
      [nil, nil, n] -> convert_char_number(n)
      ['n', nil, n] -> convert_char_number(n)
      # ISO 8601 type date
      [nil, 'd', d] -> convert_date_or_time(d)
      ['n', 'd', d] -> convert_date_or_time(d)
      ['d', 'd', d] -> convert_iso_date(d)
      # Type formula w/ string
      ['str', _, s] -> List.to_string(s)
      # Type boolean
      ['b', _, s] -> s == '1'
      # Type string
      ['inlineStr', _, s] -> List.to_string(s)
      # Unmapped type
      _ -> raise "Unmapped attribute #{Enum.at(list, 0)}. Unable to process"
    end
  end

  defp convert_iso_date(value) do
    value |> List.to_string() |> Date.from_iso8601() |> elem(1) |> Date.to_erl()
  end

  defp convert_date_or_time(value) do
    str = List.to_string(value)

    if str == "0" || String.match?(str, ~r/\d\.\d+/) do
      ConvertDateTime.from_charlist(value)
    else
      ConvertDate.from_serial(value)
    end
  end

  defp find_styles(nil, _index), do: nil

  defp find_styles(tid, index) do
    tid
    |> :ets.lookup(index)
    |> List.first()
    |> case do
      nil ->
        nil

      {_, i} ->
        i
    end
  end

  defp find_string(nil, _index), do: nil

  defp find_string(tid, index) do
    tid
    |> :ets.lookup(index)
    |> List.first()
    |> elem(1)
  end
end
