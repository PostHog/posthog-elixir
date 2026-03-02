defmodule PostHog.FeatureFlags.PropertyMatcherTest do
  use ExUnit.Case, async: true

  alias PostHog.FeatureFlags.PropertyMatcher
  alias PostHog.FeatureFlags.PropertyMatcher.InconclusiveMatchError

  describe "parse_semver/1" do
    test "parses basic semver" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3")
    end

    test "parses semver with v prefix" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("v1.2.3")
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("V1.2.3")
    end

    test "strips whitespace" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("  1.2.3  ")
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("\t1.2.3\n")
    end

    test "strips pre-release suffix" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3-alpha")
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3-beta.1")
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3-rc.2")
    end

    test "strips build metadata suffix" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3+build")
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3+build.123")
    end

    test "strips both pre-release and build metadata" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3-alpha+build")
    end

    test "defaults missing components to 0" do
      assert {:ok, {1, 2, 0}} = PropertyMatcher.parse_semver("1.2")
      assert {:ok, {1, 0, 0}} = PropertyMatcher.parse_semver("1")
    end

    test "ignores extra components beyond the third" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3.4")
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("1.2.3.4.5")
    end

    test "parses leading zeros" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("01.02.03")
    end

    test "handles combined edge cases" do
      assert {:ok, {1, 2, 3}} = PropertyMatcher.parse_semver("  v1.2.3-alpha+build  ")
    end

    test "returns error for empty string" do
      assert {:error, "Invalid semver format"} = PropertyMatcher.parse_semver("")
    end

    test "returns error for non-numeric parts" do
      assert {:error, "Invalid semver format"} = PropertyMatcher.parse_semver("abc")
      assert {:error, "Invalid semver format"} = PropertyMatcher.parse_semver("a.b.c")
    end

    test "returns error for leading dot" do
      assert {:error, "Invalid semver format"} = PropertyMatcher.parse_semver(".1.2.3")
    end
  end

  describe "semver_eq operator" do
    test "matches equal versions" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "matches with v prefix" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"},
                 %{"version" => "v1.2.3"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "v1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "matches with pre-release stripped" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"},
                 %{"version" => "1.2.3-alpha"}
               )
    end

    test "does not match different versions" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )
    end

    test "handles partial versions" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2"},
                 %{"version" => "1.2.0"}
               )
    end
  end

  describe "semver_neq operator" do
    test "matches different versions" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_neq", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )
    end

    test "does not match equal versions" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_neq", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "handles v prefix" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_neq", "value" => "v1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end
  end

  describe "semver_gt operator" do
    test "matches when override is greater" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gt", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gt", "value" => "1.2.3"},
                 %{"version" => "1.3.0"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gt", "value" => "1.2.3"},
                 %{"version" => "2.0.0"}
               )
    end

    test "does not match when override is equal" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gt", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "does not match when override is less" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gt", "value" => "1.2.3"},
                 %{"version" => "1.2.2"}
               )
    end
  end

  describe "semver_gte operator" do
    test "matches when override is greater" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gte", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )
    end

    test "matches when override is equal" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gte", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "does not match when override is less" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_gte", "value" => "1.2.3"},
                 %{"version" => "1.2.2"}
               )
    end
  end

  describe "semver_lt operator" do
    test "matches when override is less" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lt", "value" => "1.2.3"},
                 %{"version" => "1.2.2"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lt", "value" => "1.2.3"},
                 %{"version" => "1.1.9"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lt", "value" => "1.2.3"},
                 %{"version" => "0.9.9"}
               )
    end

    test "does not match when override is equal" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lt", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "does not match when override is greater" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lt", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )
    end
  end

  describe "semver_lte operator" do
    test "matches when override is less" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lte", "value" => "1.2.3"},
                 %{"version" => "1.2.2"}
               )
    end

    test "matches when override is equal" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lte", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )
    end

    test "does not match when override is greater" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_lte", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )
    end
  end

  describe "tilde_bounds/1" do
    test "returns correct bounds" do
      assert {{1, 2, 3}, {1, 3, 0}} = PropertyMatcher.tilde_bounds("1.2.3")
    end

    test "handles partial versions" do
      assert {{1, 2, 0}, {1, 3, 0}} = PropertyMatcher.tilde_bounds("1.2")
    end
  end

  describe "semver_tilde operator" do
    test "matches versions in tilde range" do
      # ~1.2.3 means >=1.2.3 and <1.3.0
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.2.4"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.2.99"}
               )
    end

    test "does not match versions below lower bound" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.2.2"}
               )
    end

    test "does not match versions at or above upper bound" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.3.0"}
               )

      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "2.0.0"}
               )
    end

    test "handles boundary values" do
      # Lower bound inclusive
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )

      # Upper bound exclusive
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_tilde", "value" => "1.2.3"},
                 %{"version" => "1.3.0"}
               )
    end
  end

  describe "caret_bounds/1" do
    test "handles major > 0" do
      # ^1.2.3 means >=1.2.3 <2.0.0
      assert {{1, 2, 3}, {2, 0, 0}} = PropertyMatcher.caret_bounds("1.2.3")
    end

    test "handles major = 0, minor > 0" do
      # ^0.2.3 means >=0.2.3 <0.3.0
      assert {{0, 2, 3}, {0, 3, 0}} = PropertyMatcher.caret_bounds("0.2.3")
    end

    test "handles major = 0, minor = 0" do
      # ^0.0.3 means >=0.0.3 <0.0.4
      assert {{0, 0, 3}, {0, 0, 4}} = PropertyMatcher.caret_bounds("0.0.3")
    end
  end

  describe "semver_caret operator" do
    test "major > 0: matches versions in range" do
      # ^1.2.3 means >=1.2.3 <2.0.0
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "1.2.3"},
                 %{"version" => "1.2.3"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "1.2.3"},
                 %{"version" => "1.9.9"}
               )
    end

    test "major > 0: does not match versions at major boundary" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "1.2.3"},
                 %{"version" => "2.0.0"}
               )
    end

    test "major = 0, minor > 0: matches versions in range" do
      # ^0.2.3 means >=0.2.3 <0.3.0
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "0.2.3"},
                 %{"version" => "0.2.3"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "0.2.3"},
                 %{"version" => "0.2.99"}
               )
    end

    test "major = 0, minor > 0: does not match versions at minor boundary" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "0.2.3"},
                 %{"version" => "0.3.0"}
               )
    end

    test "major = 0, minor = 0: matches versions in range" do
      # ^0.0.3 means >=0.0.3 <0.0.4
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "0.0.3"},
                 %{"version" => "0.0.3"}
               )
    end

    test "major = 0, minor = 0: does not match versions at patch boundary" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "0.0.3"},
                 %{"version" => "0.0.4"}
               )

      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_caret", "value" => "0.0.3"},
                 %{"version" => "0.0.2"}
               )
    end
  end

  describe "wildcard_bounds/1" do
    test "handles major wildcard" do
      # 1.* means >=1.0.0 <2.0.0
      assert {{1, 0, 0}, {2, 0, 0}} = PropertyMatcher.wildcard_bounds("1.*")
      assert {{1, 0, 0}, {2, 0, 0}} = PropertyMatcher.wildcard_bounds("1")
    end

    test "handles minor wildcard" do
      # 1.2.* means >=1.2.0 <1.3.0
      assert {{1, 2, 0}, {1, 3, 0}} = PropertyMatcher.wildcard_bounds("1.2.*")
      assert {{1, 2, 0}, {1, 3, 0}} = PropertyMatcher.wildcard_bounds("1.2")
    end
  end

  describe "semver_wildcard operator" do
    test "major wildcard matches versions in range" do
      # 1.* means >=1.0.0 <2.0.0
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.*"},
                 %{"version" => "1.0.0"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.*"},
                 %{"version" => "1.9.9"}
               )
    end

    test "major wildcard does not match versions outside range" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.*"},
                 %{"version" => "0.9.9"}
               )

      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.*"},
                 %{"version" => "2.0.0"}
               )
    end

    test "minor wildcard matches versions in range" do
      # 1.2.* means >=1.2.0 <1.3.0
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.2.*"},
                 %{"version" => "1.2.0"}
               )

      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.2.*"},
                 %{"version" => "1.2.99"}
               )
    end

    test "minor wildcard does not match versions outside range" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.2.*"},
                 %{"version" => "1.1.9"}
               )

      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_wildcard", "value" => "1.2.*"},
                 %{"version" => "1.3.0"}
               )
    end
  end

  describe "error handling" do
    test "raises for missing property key" do
      assert_raise InconclusiveMatchError,
                   "Can't match properties without a given property value",
                   fn ->
                     PropertyMatcher.match_property(
                       %{"key" => "version", "operator" => "semver_eq", "value" => "1.0.0"},
                       %{"other_key" => "1.0.0"}
                     )
                   end
    end

    test "raises for invalid override value semver" do
      assert_raise InconclusiveMatchError,
                   "Person property value 'not-a-version' is not a valid semver",
                   fn ->
                     PropertyMatcher.match_property(
                       %{"key" => "version", "operator" => "semver_eq", "value" => "1.0.0"},
                       %{"version" => "not-a-version"}
                     )
                   end
    end

    test "raises for invalid flag value semver" do
      assert_raise InconclusiveMatchError,
                   "Flag semver value 'invalid' is not a valid semver",
                   fn ->
                     PropertyMatcher.match_property(
                       %{"key" => "version", "operator" => "semver_eq", "value" => "invalid"},
                       %{"version" => "1.0.0"}
                     )
                   end
    end

    test "raises for invalid tilde value" do
      assert_raise InconclusiveMatchError, fn ->
        PropertyMatcher.match_property(
          %{"key" => "version", "operator" => "semver_tilde", "value" => "invalid"},
          %{"version" => "1.0.0"}
        )
      end
    end

    test "raises for invalid caret value" do
      assert_raise InconclusiveMatchError, fn ->
        PropertyMatcher.match_property(
          %{"key" => "version", "operator" => "semver_caret", "value" => "invalid"},
          %{"version" => "1.0.0"}
        )
      end
    end

    test "raises for invalid wildcard value" do
      assert_raise InconclusiveMatchError, fn ->
        PropertyMatcher.match_property(
          %{"key" => "version", "operator" => "semver_wildcard", "value" => "*"},
          %{"version" => "1.0.0"}
        )
      end
    end

    test "raises for unknown operator" do
      assert_raise InconclusiveMatchError, "Unknown operator: invalid_op", fn ->
        PropertyMatcher.match_property(
          %{"key" => "version", "operator" => "invalid_op", "value" => "1.0.0"},
          %{"version" => "1.0.0"}
        )
      end
    end

    test "returns false for null property value" do
      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.0.0"},
                 %{"version" => nil}
               )
    end
  end

  describe "edge cases" do
    test "handles 4-part versions" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"},
                 %{"version" => "1.2.3.4"}
               )
    end

    test "handles versions with leading zeros" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "1.2.3"},
                 %{"version" => "01.02.03"}
               )
    end

    test "handles whitespace in versions" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "  1.2.3  "},
                 %{"version" => "1.2.3"}
               )
    end

    test "handles v-prefix on both sides" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "version", "operator" => "semver_eq", "value" => "v1.2.3"},
                 %{"version" => "V1.2.3"}
               )
    end
  end

  describe "equality operators" do
    test "exact matches case-insensitively" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "exact", "value" => "test"},
                 %{"name" => "TEST"}
               )
    end

    test "exact matches list values" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "exact", "value" => ["foo", "bar"]},
                 %{"name" => "foo"}
               )

      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "exact", "value" => ["foo", "bar"]},
                 %{"name" => "baz"}
               )
    end

    test "is_not negates exact" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "is_not", "value" => "test"},
                 %{"name" => "other"}
               )

      assert false ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "is_not", "value" => "test"},
                 %{"name" => "test"}
               )
    end

    test "is_set returns true if key exists" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "is_set", "value" => nil},
                 %{"name" => "any"}
               )
    end
  end

  describe "string operators" do
    test "icontains matches case-insensitively" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "icontains", "value" => "test"},
                 %{"name" => "a TEST value"}
               )
    end

    test "not_icontains excludes matches" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "not_icontains", "value" => "test"},
                 %{"name" => "no match"}
               )
    end

    test "regex matches patterns" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "email", "operator" => "regex", "value" => "^test@"},
                 %{"email" => "test@example.com"}
               )
    end

    test "not_regex excludes patterns" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "email", "operator" => "not_regex", "value" => "^test@"},
                 %{"email" => "other@example.com"}
               )
    end
  end

  describe "numeric operators" do
    test "gt compares numerically" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "count", "operator" => "gt", "value" => "5"},
                 %{"count" => 10}
               )
    end

    test "gte compares numerically" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "count", "operator" => "gte", "value" => "10"},
                 %{"count" => 10}
               )
    end

    test "lt compares numerically" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "count", "operator" => "lt", "value" => "10"},
                 %{"count" => 5}
               )
    end

    test "lte compares numerically" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "count", "operator" => "lte", "value" => "10"},
                 %{"count" => 10}
               )
    end

    test "falls back to string comparison when not numeric" do
      assert true ==
               PropertyMatcher.match_property(
                 %{"key" => "name", "operator" => "gt", "value" => "a"},
                 %{"name" => "b"}
               )
    end
  end
end
