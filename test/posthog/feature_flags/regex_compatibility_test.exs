defmodule PostHog.FeatureFlags.RegexCompatibilityTest do
  use ExUnit.Case, async: true

  alias PostHog.FeatureFlags.LocalEvaluator
  alias PostHog.FeatureFlags.Result

  defp evaluate(pattern, input, operator, options \\ []) do
    property = %{"key" => "prop", "operator" => operator, "value" => pattern}

    property = Map.put(property, "negation", options[:negated?] == true)

    reference = %{
      "type" => "cohort",
      "value" => "1",
      "operator" => if(options[:not_in?], do: "not_in", else: "in"),
      "negation" => options[:reference_negated?] == true
    }

    group = %{"type" => "AND", "values" => [property]}

    group =
      if options[:group_negated?],
        do: %{"type" => "AND", "values" => [Map.put(group, "negation", true)]},
        else: group

    flag = %{
      "id" => 1,
      "key" => "regex",
      "active" => true,
      "filters" => %{
        "groups" => [
          %{
            "properties" => if(options[:direct?], do: [property], else: [reference]),
            "rollout_percentage" => 100
          }
        ]
      }
    }

    definitions = %{
      flags: [flag],
      flags_by_key: %{"regex" => flag},
      group_type_mapping: %{},
      cohorts: %{"1" => group},
      minimal_flag_called_events: false
    }

    LocalEvaluator.evaluate(definitions, %{distinct_id: "user", person_properties: input})
  end

  # These are service-checked probes, not expectations derived from PCRE.
  for operator <- ["regex", "not_regex"] do
    @operator operator
    for {name, pattern, input} <- [
          {"Unicode digits", "^\\d+$", "١"},
          {"astral digits", "^\\d+$", "𝟙"},
          {"Unicode word", "^\\w+$", "é"},
          {"Unicode whitespace", "^\\s$", "\u00a0"},
          {"Unicode property", "^\\p{L}+$", "é"},
          {"Unicode property ASCII", "^\\p{L}+$", "abc"},
          {"astral scalar", "^.$", "😀"},
          {"Unicode pattern", "^😀?$", ""},
          {"inline flags", "(?i)^null$", "NULL"},
          {"scoped flags", "(?i:^null$)", "NULL"},
          {"lookahead", "a(?=b)", "ab"},
          {"variable lookbehind", "(?<=a+)b", "aab"},
          {"backreference", "(a)\\1", "aa"},
          {"POSIX class", "^[[:alpha:]]+$", "abc"},
          {"nested intersection", "^[a-z&&[^aeiou]]+$", "bcdf"},
          {"flat intersection", "^[a&&b]$", "a"},
          {"difference", "^[a-z--b]$", "b"},
          {"symmetric difference", "^[a~~b]$", "~"},
          {"empty class", "[]", "a"},
          {"negated empty class", "[^]", "a"},
          {"octal", "\\141", "a"},
          {"identity escape", "\\q", "q"},
          {"hex scalar", "^\\x{41}$", "A"},
          {"absolute anchor", "\\Afoo\\z", "foo"},
          {"possessive repetition", "a++", "aa"},
          {"bounded possessive repetition", "a{2}+", "aa"},
          {"open repetition", "a{,2}", "aa"},
          {"stacked repetition", "a*{2}", "aa"},
          {"literal braces", "{foo}", "{foo}"},
          {"shorthand range start", "[\\s-9]", "-"},
          {"shorthand range end", "[a-\\d]", "-"},
          {"quantified start", "^?https?://", "https://a"},
          {"quantified end", "$?", "x"},
          {"leading repetition", "{2}", "x"},
          {"alternation repetition", "a|{2}", "x"},
          {"group repetition", "({2})", "x"},
          {"noncapturing repetition", "(?:{2})", "x"},
          {"empty group repetition", "()+", "x"},
          {"empty noncapturing repetition", "(?:)*", "x"},
          {"empty bounded repetition", "(?:){2}", "x"},
          {"oversized repetition", "a{0,4294967296}", "x"},
          {"word boundary budget", ".*\\bbot\\b.*", String.duplicate("a", 140)},
          {"nonword boundary budget", ".*\\Bbot\\B.*", String.duplicate("a", 140)},
          {"Rust word edges", "\\<foo\\>", "foo"},
          {"class punctuation", "[\\@]", "@"},
          {"class nonword boundary", "[\\B]", "B"}
        ] do
      @pattern pattern
      @input input
      test "#{operator} defers #{name}, including cohort negation" do
        for negated? <- [false, true] do
          result = evaluate(@pattern, %{"prop" => @input}, @operator, negated?: negated?)
          assert result.results == %{}
          assert result.unresolved == MapSet.new(["regex"])
        end
      end
    end

    for pattern <- [
          "(*FAIL)",
          "(*ACCEPT)",
          "(*COMMIT)",
          "(*LIMIT_MATCH=1)a",
          "*",
          "?*",
          "*a",
          "+a",
          "?a",
          "a|*b",
          "a|+b",
          "a|?b",
          "(*a)",
          "(+a)",
          "(?:*a)",
          "(?:+a)",
          "(?:?a)"
        ] do
      @pattern pattern
      test "#{operator} defers nonportable quantifier #{inspect(pattern)} through negation" do
        for options <- [
              [direct?: true],
              [direct?: true, negated?: true],
              [],
              [negated?: true],
              [reference_negated?: true],
              [group_negated?: true],
              [not_in?: true]
            ] do
          result = evaluate(@pattern, %{"prop" => "a"}, @operator, options)
          assert result.results == %{}
          assert result.unresolved == MapSet.new(["regex"])
        end
      end
    end

    for pattern <- ["\\v", "^\\v$", "[\\v]", "^[\\v]$"],
        {name, input} <- [{"LF", "\n"}, {"CR", "\r"}, {"FF", "\f"}, {"VT", "\u000b"}] do
      @pattern pattern
      @input input
      test "#{operator} defers vertical escape #{inspect(pattern)} on #{name}" do
        for options <- [[direct?: true], [], [negated?: true], [not_in?: true]] do
          result = evaluate(@pattern, %{"prop" => @input}, @operator, options)
          assert result.results == %{}
          assert result.unresolved == MapSet.new(["regex"])
        end
      end
    end

    test "#{operator} keeps match-limit errors inconclusive through negation" do
      pattern = "^(a+)+$|^a+\\n$"
      input = String.duplicate("a", 30) <> "\n"
      {:ok, compiled} = Regex.compile(pattern, [:dollar_endonly])

      assert {:error, :match_limit} =
               :re.run(input, Regex.re_pattern(compiled), [:report_errors, {:capture, :none}])

      for options <- [
            [direct?: true],
            [direct?: true, negated?: true],
            [],
            [negated?: true],
            [reference_negated?: true],
            [group_negated?: true],
            [not_in?: true]
          ] do
        result = evaluate(pattern, %{"prop" => input}, @operator, options)
        assert result.results == %{}
        assert result.unresolved == MapSet.new(["regex"])
      end
    end

    test "#{operator} keeps literal and hexadecimal vertical tab local" do
      for pattern <- [
            "\u000b",
            "^\u000b$",
            "[\u000b]",
            "^[\u000b]$",
            "\\x0b",
            "^\\x0b$",
            "[\\x0b]",
            "^[\\x0b]$"
          ],
          input <- ["\n", "\r", "\f", "\u000b"] do
        result = evaluate(pattern, %{"prop" => input}, @operator)
        matches? = input == "\u000b"
        expected = if @operator == "regex", do: matches?, else: not matches?
        assert %Result{enabled: ^expected, locally_evaluated: true} = result.results["regex"]
        assert MapSet.size(result.unresolved) == 0
      end
    end

    test "#{operator} keeps empty and full-range ASCII input local" do
      for {input, matches?} <- [
            {"", false},
            {<<0>>, false},
            {<<127>>, false},
            {:binary.list_to_bin(Enum.to_list(0..127)), true},
            {String.duplicate("a", 65_536), true}
          ] do
        result = evaluate("a", %{"prop" => input}, @operator, direct?: true)
        expected = if @operator == "regex", do: matches?, else: not matches?
        assert %Result{enabled: ^expected, locally_evaluated: true} = result.results["regex"]
        assert MapSet.size(result.unresolved) == 0
      end
    end

    test "#{operator} preserves fallback and special patterns for non-ASCII binary edges" do
      ascii = String.duplicate("a", 65_536)

      for input <- [<<128>> <> ascii, ascii <> <<255>>, "é" <> ascii, ascii <> "é"] do
        result = evaluate("a", %{"prop" => input}, @operator, direct?: true)
        assert result.results == %{}
        assert result.unresolved == MapSet.new(["regex"])

        empty = evaluate("", %{"prop" => input}, @operator, direct?: true)
        expected = @operator == "regex"
        assert %Result{enabled: ^expected} = empty.results["regex"]
        assert MapSet.size(empty.unresolved) == 0

        invalid = evaluate("[", %{"prop" => input}, @operator, direct?: true)
        assert %Result{enabled: false} = invalid.results["regex"]
        assert MapSet.size(invalid.unresolved) == 0
      end
    end

    test "#{operator} preserves fallback for property stringification failures" do
      result = evaluate("a", %{"prop" => %{}}, @operator, direct?: true)
      assert result.results == %{}
      assert result.unresolved == MapSet.new(["regex"])
    end

    test "#{operator} keeps shared searches local" do
      for {pattern, input, matches?} <- [
            {"pro", "a pro plan", true},
            {"^pro$", "a pro plan", false},
            {"^pro$", "PRO", false},
            {"^\\d+$", "123", true},
            {"^[\\w.+-]+@example\\.com$", "a.b+tag@example.com", true},
            {"^(?:ab|cd){2,3}$", "abcdab", true},
            {"^a*$", "", true},
            {"^a+$", "aa", true},
            {"^a?$", "", true},
            {"^(a)+$", "aa", true},
            {"^(?:a)*$", "aa", true},
            {"^a+?$", "aa", true},
            {"^\\\\p\\{L\\}$", "\\p{L}", true},
            {"^\\(\\?i\\)$", "(?i)", true},
            {"^\\x41+$", "AA", true},
            {"^v$", "v", true},
            {"^\\\\v$", "\\v", true},
            {"[\\b]", "\b", true},
            {"^a\\-b$", "a-b", true},
            {"\\@example\\.com$", "a@example.com", true},
            {"^a\\:b$", "a:b", true},
            {"^a\\_b$", "a_b", true},
            {"^a\\=b$", "a=b", true},
            {"^a\\ b$", "a b", true},
            {"^\\^?$", "", true},
            {"^\\${2}$", "$$", true},
            {"^\\({2}$", "((", true},
            {"^\\|{2}$", "||", true},
            {"^[\\^$?]+$", "$?^", true},
            {"^[\\w-]+$", "a-b", true},
            {"", "", true},
            {"", "é", true},
            {"", "\r", true},
            {"^foo$", "foo\n", false},
            {"^foo$", "a\nfoo\nb", false},
            {"^.$", "\r", true}
          ] do
        result = evaluate(pattern, %{"prop" => input}, @operator)
        expected = if @operator == "regex", do: matches?, else: not matches?

        assert %Result{enabled: ^expected, locally_evaluated: true} = result.results["regex"],
               inspect({pattern, input, result})

        assert MapSet.size(result.unresolved) == 0
      end
    end

    test "#{operator} does not negate proven invalid syntax" do
      for pattern <- ["[", "(", "[abc", "(abc", "abc)", "[z-a]", "a{2,1}"],
          input <- ["value", "é", "\r"],
          negated? <- [false, true] do
        result =
          evaluate(pattern, %{"prop" => input}, @operator, direct?: true, negated?: negated?)

        assert %Result{enabled: false, locally_evaluated: true} = result.results["regex"]
        assert MapSet.size(result.unresolved) == 0
      end
    end

    test "#{operator} keeps invalid searches inconclusive through outer cohort negation" do
      for pattern <- ["[", "(", "*", "?*"],
          options <- [
            [],
            [negated?: true],
            [reference_negated?: true],
            [not_in?: true],
            [group_negated?: true],
            [negated?: true, not_in?: true]
          ] do
        result = evaluate(pattern, %{"prop" => "value"}, @operator, options)
        assert result.results == %{}
        assert result.unresolved == MapSet.new(["regex"])
      end
    end

    test "#{operator} still negates valid cohort comparisons" do
      result = evaluate("^abc$", %{"prop" => "abc"}, @operator, negated?: true)
      expected = @operator == "not_regex"
      assert %Result{enabled: ^expected} = result.results["regex"]
    end

    test "#{operator} keeps a missing property unresolved and explicit nil unchanged" do
      assert evaluate("", %{}, @operator).unresolved == MapSet.new(["regex"])
      assert %Result{enabled: false} = evaluate("", %{"prop" => nil}, @operator).results["regex"]
    end
  end
end
