defmodule PostHog.FeatureFlags.PropertyMatcher do
  @moduledoc """
  Provides property matching logic for local feature flag evaluation.

  This module is used to match person or group properties against feature flag
  conditions during local evaluation. It supports various operators including
  equality, string matching, numeric comparison, date comparison, and semantic
  versioning (semver) comparison.
  """

  @type semver :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @equality_operators ~w(exact is_not is_set is_not_set)
  @string_operators ~w(icontains not_icontains regex not_regex)
  @numeric_operators ~w(gt gte lt lte)
  @date_operators ~w(is_date_before is_date_after)
  @semver_comparison_operators ~w(semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte)
  @semver_range_operators ~w(semver_tilde semver_caret semver_wildcard)
  @semver_operators @semver_comparison_operators ++ @semver_range_operators

  @property_operators @equality_operators ++
                        @string_operators ++
                        @numeric_operators ++ @date_operators ++ @semver_operators

  defmodule InconclusiveMatchError do
    @moduledoc """
    Raised when a property match cannot be determined conclusively.

    This can happen when:
    - The property key is missing from the provided values
    - The property value cannot be parsed (e.g., invalid semver, invalid date)
    - The operator is unknown
    """
    defexception [:message]
  end

  @doc """
  Matches a property condition against provided property values.

  ## Parameters

  - `property` - A map containing the property condition with keys:
    - `"key"` - The property key to match
    - `"operator"` - The comparison operator (defaults to "exact")
    - `"value"` - The expected value for comparison
  - `property_values` - A map of property keys to their values

  ## Returns

  - `true` if the property matches
  - `false` if the property does not match

  ## Raises

  - `InconclusiveMatchError` if the match cannot be determined

  ## Examples

      iex> PropertyMatcher.match_property(%{"key" => "version", "operator" => "semver_gt", "value" => "1.0.0"}, %{"version" => "2.0.0"})
      true

      iex> PropertyMatcher.match_property(%{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"}, %{"version" => "v1.2.3"})
      true
  """
  @spec match_property(map(), map()) :: boolean()
  def match_property(property, property_values) do
    key = Map.get(property, "key")
    operator = Map.get(property, "operator", "exact")
    value = Map.get(property, "value")

    unless operator in @property_operators do
      raise InconclusiveMatchError, message: "Unknown operator: #{operator}"
    end

    unless Map.has_key?(property_values, key) do
      raise InconclusiveMatchError,
        message: "Can't match properties without a given property value"
    end

    if operator == "is_not_set" do
      raise InconclusiveMatchError,
        message: "Can't match properties with operator is_not_set"
    end

    override_value = Map.get(property_values, key)

    # For most operators, null values should return false
    if operator not in ~w(is_not) and is_nil(override_value) do
      false
    else
      do_match_property(operator, value, override_value)
    end
  end

  # Equality operators
  defp do_match_property("exact", value, override_value) do
    compute_exact_match(value, override_value)
  end

  defp do_match_property("is_not", value, override_value) do
    not compute_exact_match(value, override_value)
  end

  defp do_match_property("is_set", _value, _override_value) do
    # If we reach here, the key exists in property_values
    true
  end

  # String operators
  defp do_match_property("icontains", value, override_value) do
    String.contains?(
      String.downcase(to_string(override_value)),
      String.downcase(to_string(value))
    )
  end

  defp do_match_property("not_icontains", value, override_value) do
    not String.contains?(
      String.downcase(to_string(override_value)),
      String.downcase(to_string(value))
    )
  end

  defp do_match_property("regex", value, override_value) do
    case Regex.compile(to_string(value)) do
      {:ok, regex} -> Regex.match?(regex, to_string(override_value))
      {:error, _} -> false
    end
  end

  defp do_match_property("not_regex", value, override_value) do
    case Regex.compile(to_string(value)) do
      {:ok, regex} -> not Regex.match?(regex, to_string(override_value))
      {:error, _} -> true
    end
  end

  # Numeric comparison operators
  defp do_match_property(operator, value, override_value)
       when operator in ~w(gt gte lt lte) do
    compare_numeric(operator, value, override_value)
  end

  # Date operators
  defp do_match_property("is_date_before", value, override_value) do
    compare_dates(:before, value, override_value)
  end

  defp do_match_property("is_date_after", value, override_value) do
    compare_dates(:after, value, override_value)
  end

  # Semver comparison operators
  defp do_match_property("semver_eq", value, override_value) do
    {flag_semver, override_semver} = parse_both_semvers(value, override_value)
    override_semver == flag_semver
  end

  defp do_match_property("semver_neq", value, override_value) do
    {flag_semver, override_semver} = parse_both_semvers(value, override_value)
    override_semver != flag_semver
  end

  defp do_match_property("semver_gt", value, override_value) do
    {flag_semver, override_semver} = parse_both_semvers(value, override_value)
    override_semver > flag_semver
  end

  defp do_match_property("semver_gte", value, override_value) do
    {flag_semver, override_semver} = parse_both_semvers(value, override_value)
    override_semver >= flag_semver
  end

  defp do_match_property("semver_lt", value, override_value) do
    {flag_semver, override_semver} = parse_both_semvers(value, override_value)
    override_semver < flag_semver
  end

  defp do_match_property("semver_lte", value, override_value) do
    {flag_semver, override_semver} = parse_both_semvers(value, override_value)
    override_semver <= flag_semver
  end

  # Semver range operators
  defp do_match_property("semver_tilde", value, override_value) do
    override_semver = parse_override_semver(override_value)
    {lower, upper} = tilde_bounds(value)
    override_semver >= lower and override_semver < upper
  end

  defp do_match_property("semver_caret", value, override_value) do
    override_semver = parse_override_semver(override_value)
    {lower, upper} = caret_bounds(value)
    override_semver >= lower and override_semver < upper
  end

  defp do_match_property("semver_wildcard", value, override_value) do
    override_semver = parse_override_semver(override_value)
    {lower, upper} = wildcard_bounds(value)
    override_semver >= lower and override_semver < upper
  end

  # Helper functions

  defp compute_exact_match(value, override_value) when is_list(value) do
    override_str = to_string(override_value) |> String.downcase()
    Enum.any?(value, fn v -> String.downcase(to_string(v)) == override_str end)
  end

  defp compute_exact_match(value, override_value) do
    String.downcase(to_string(value)) == String.downcase(to_string(override_value))
  end

  defp compare_numeric(operator, value, override_value) do
    parsed_value = parse_number(value)
    parsed_override = parse_number(override_value)

    # If both can be parsed as numbers, compare numerically
    # Otherwise, compare as strings
    case {parsed_value, parsed_override} do
      {{:ok, v}, {:ok, ov}} ->
        compare_values(operator, ov, v)

      _ ->
        compare_values(operator, to_string(override_value), to_string(value))
    end
  end

  defp parse_number(value) when is_number(value), do: {:ok, value / 1}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} -> {:ok, num}
      {num, _rest} -> {:ok, num}
      :error -> :error
    end
  end

  defp parse_number(_), do: :error

  defp compare_values("gt", lhs, rhs), do: lhs > rhs
  defp compare_values("gte", lhs, rhs), do: lhs >= rhs
  defp compare_values("lt", lhs, rhs), do: lhs < rhs
  defp compare_values("lte", lhs, rhs), do: lhs <= rhs

  defp compare_dates(direction, value, override_value) do
    parsed_date = parse_flag_date(value)

    case parse_override_date(override_value) do
      {:ok, override_date} ->
        case direction do
          :before -> DateTime.compare(override_date, parsed_date) == :lt
          :after -> DateTime.compare(override_date, parsed_date) == :gt
        end

      :error ->
        raise InconclusiveMatchError, message: "The date provided is not a valid format"
    end
  end

  @seconds_per_hour 3600
  @seconds_per_day 86_400
  @seconds_per_week 7 * @seconds_per_day

  defp parse_flag_date(value) do
    value_str = to_string(value)

    with :error <- parse_relative_date(value_str),
         :error <- parse_iso_datetime(value_str),
         :error <- parse_iso_date(value_str) do
      raise InconclusiveMatchError,
        message: "The date set on the flag is not a valid format"
    end
  end

  defp parse_iso_datetime(value_str) do
    case DateTime.from_iso8601(value_str) do
      {:ok, date, _offset} -> date
      {:error, _} -> :error
    end
  end

  defp parse_iso_date(value_str) do
    case Date.from_iso8601(value_str) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      {:error, _} -> :error
    end
  end

  defp parse_relative_date(value) do
    regex = ~r/^-?(?<number>[0-9]+)(?<interval>[a-z])$/

    case Regex.named_captures(regex, value) do
      %{"number" => number_str, "interval" => interval} ->
        parse_relative_date_interval(number_str, interval)

      nil ->
        :error
    end
  end

  defp parse_relative_date_interval(number_str, interval) do
    number = String.to_integer(number_str)

    if number >= 10_000 do
      :error
    else
      apply_interval(DateTime.utc_now(), interval, number)
    end
  end

  defp apply_interval(now, "h", number),
    do: DateTime.add(now, -number * @seconds_per_hour, :second)

  defp apply_interval(now, "d", number),
    do: DateTime.add(now, -number * @seconds_per_day, :second)

  defp apply_interval(now, "w", number),
    do: DateTime.add(now, -number * @seconds_per_week, :second)

  defp apply_interval(now, "m", number), do: shift_months(now, -number)
  defp apply_interval(now, "y", number), do: shift_years(now, -number)
  defp apply_interval(_now, _interval, _number), do: :error

  defp shift_months(datetime, months) do
    date = DateTime.to_date(datetime)
    new_date = Date.add(date, months * 30)
    DateTime.new!(new_date, DateTime.to_time(datetime), "Etc/UTC")
  end

  defp shift_years(datetime, years) do
    date = DateTime.to_date(datetime)
    new_date = Date.add(date, years * 365)
    DateTime.new!(new_date, DateTime.to_time(datetime), "Etc/UTC")
  end

  defp parse_override_date(%DateTime{} = dt), do: {:ok, dt}

  defp parse_override_date(%Date{} = date) do
    {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
  end

  defp parse_override_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} ->
        {:ok, date}

      {:error, _} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_override_date(_), do: :error

  # Semver parsing and bounds functions

  @doc """
  Parses a semver string into a comparable tuple of integers.

  ## Parsing rules

  1. Strips leading/trailing whitespace
  2. Strips `v` or `V` prefix (e.g., "v1.2.3" → "1.2.3")
  3. Strips pre-release and build metadata suffixes (split on `-` or `+`, take first part)
  4. Splits on `.` and parses first 3 components as integers
  5. Defaults missing components to 0 (e.g., "1.2" → {1, 2, 0}, "1" → {1, 0, 0})
  6. Ignores extra components beyond the third (e.g., "1.2.3.4" → {1, 2, 3})

  ## Examples

      iex> PropertyMatcher.parse_semver("1.2.3")
      {:ok, {1, 2, 3}}

      iex> PropertyMatcher.parse_semver("v1.2.3")
      {:ok, {1, 2, 3}}

      iex> PropertyMatcher.parse_semver("1.2.3-alpha+build")
      {:ok, {1, 2, 3}}

      iex> PropertyMatcher.parse_semver("1.2")
      {:ok, {1, 2, 0}}

      iex> PropertyMatcher.parse_semver("invalid")
      {:error, "Invalid semver format"}
  """
  @spec parse_semver(String.t() | any()) :: {:ok, semver()} | {:error, String.t()}
  def parse_semver(value) do
    text =
      value
      |> to_string()
      |> String.trim()
      |> String.trim_leading("v")
      |> String.trim_leading("V")

    # Strip pre-release/build metadata suffix
    text =
      text
      |> String.split("-", parts: 2)
      |> hd()
      |> String.split("+", parts: 2)
      |> hd()

    parts = String.split(text, ".")

    # Reject empty string, empty list, or leading dot (first part is empty)
    if parts == [""] or parts == [] or hd(parts) == "" do
      {:error, "Invalid semver format"}
    else
      try do
        major = parse_semver_part(Enum.at(parts, 0))
        minor = parse_semver_part(Enum.at(parts, 1))
        patch = parse_semver_part(Enum.at(parts, 2))

        {:ok, {major, minor, patch}}
      rescue
        ArgumentError -> {:error, "Invalid semver format"}
      end
    end
  end

  defp parse_semver_part(nil), do: 0
  defp parse_semver_part(""), do: 0

  defp parse_semver_part(part) do
    case Integer.parse(part) do
      {num, _rest} when num >= 0 -> num
      _ -> raise ArgumentError, "Invalid semver part"
    end
  end

  defp parse_both_semvers(flag_value, override_value) do
    override_semver = parse_override_semver(override_value)

    case parse_semver(flag_value) do
      {:ok, flag_semver} ->
        {flag_semver, override_semver}

      {:error, _} ->
        raise InconclusiveMatchError,
          message: "Flag semver value '#{flag_value}' is not a valid semver"
    end
  end

  defp parse_override_semver(override_value) do
    case parse_semver(override_value) do
      {:ok, semver} ->
        semver

      {:error, _} ->
        raise InconclusiveMatchError,
          message: "Person property value '#{override_value}' is not a valid semver"
    end
  end

  @doc """
  Computes the bounds for the tilde operator.

  `~1.2.3` means `>=1.2.3 <1.3.0` (allows patch-level changes).

  ## Examples

      iex> PropertyMatcher.tilde_bounds("1.2.3")
      {{1, 2, 3}, {1, 3, 0}}
  """
  @spec tilde_bounds(String.t()) :: {semver(), semver()}
  def tilde_bounds(value) do
    case parse_semver(value) do
      {:ok, {major, minor, patch}} ->
        {{major, minor, patch}, {major, minor + 1, 0}}

      {:error, _} ->
        raise InconclusiveMatchError,
          message: "Flag semver value '#{value}' is not valid for tilde operator"
    end
  end

  @doc """
  Computes the bounds for the caret operator.

  Follows semver spec:
  - `^1.2.3` means `>=1.2.3 <2.0.0`
  - `^0.2.3` means `>=0.2.3 <0.3.0`
  - `^0.0.3` means `>=0.0.3 <0.0.4`

  ## Examples

      iex> PropertyMatcher.caret_bounds("1.2.3")
      {{1, 2, 3}, {2, 0, 0}}

      iex> PropertyMatcher.caret_bounds("0.2.3")
      {{0, 2, 3}, {0, 3, 0}}

      iex> PropertyMatcher.caret_bounds("0.0.3")
      {{0, 0, 3}, {0, 0, 4}}
  """
  @spec caret_bounds(String.t()) :: {semver(), semver()}
  def caret_bounds(value) do
    case parse_semver(value) do
      {:ok, {major, minor, patch}} ->
        lower = {major, minor, patch}

        upper =
          cond do
            major > 0 -> {major + 1, 0, 0}
            minor > 0 -> {0, minor + 1, 0}
            true -> {0, 0, patch + 1}
          end

        {lower, upper}

      {:error, _} ->
        raise InconclusiveMatchError,
          message: "Flag semver value '#{value}' is not valid for caret operator"
    end
  end

  @doc """
  Computes the bounds for the wildcard operator.

  - `1.*` means `>=1.0.0 <2.0.0`
  - `1.2.*` means `>=1.2.0 <1.3.0`

  ## Examples

      iex> PropertyMatcher.wildcard_bounds("1.*")
      {{1, 0, 0}, {2, 0, 0}}

      iex> PropertyMatcher.wildcard_bounds("1.2.*")
      {{1, 2, 0}, {1, 3, 0}}
  """
  @spec wildcard_bounds(String.t()) :: {semver(), semver()}
  def wildcard_bounds(value) do
    cleaned =
      value
      |> to_string()
      |> String.trim()
      |> String.trim_leading("v")
      |> String.trim_leading("V")
      |> String.replace("*", "")
      |> String.trim_trailing(".")

    if cleaned == "" do
      raise InconclusiveMatchError,
        message: "Flag semver value '#{value}' is not valid for wildcard operator"
    end

    parts =
      cleaned
      |> String.split(".")
      |> Enum.filter(&(&1 != ""))

    if parts == [] do
      raise InconclusiveMatchError,
        message: "Flag semver value '#{value}' is not valid for wildcard operator"
    end

    case parse_wildcard_parts(parts) do
      {:ok, bounds} ->
        bounds

      :error ->
        raise InconclusiveMatchError,
          message: "Flag semver value '#{value}' is not valid for wildcard operator"
    end
  end

  defp parse_wildcard_parts(parts) do
    case length(parts) do
      1 ->
        with {:ok, major} <- safe_parse_int(Enum.at(parts, 0)) do
          {:ok, {{major, 0, 0}, {major + 1, 0, 0}}}
        end

      2 ->
        with {:ok, major} <- safe_parse_int(Enum.at(parts, 0)),
             {:ok, minor} <- safe_parse_int(Enum.at(parts, 1)) do
          {:ok, {{major, minor, 0}, {major, minor + 1, 0}}}
        end

      _ ->
        with {:ok, major} <- safe_parse_int(Enum.at(parts, 0)),
             {:ok, minor} <- safe_parse_int(Enum.at(parts, 1)),
             {:ok, patch} <- safe_parse_int(Enum.at(parts, 2)) do
          {:ok, {{major, minor, patch}, {major, minor, patch + 1}}}
        end
    end
  end

  defp safe_parse_int(nil), do: :error
  defp safe_parse_int(""), do: :error

  defp safe_parse_int(str) do
    case Integer.parse(str) do
      {num, _rest} when num >= 0 -> {:ok, num}
      _ -> :error
    end
  end
end
