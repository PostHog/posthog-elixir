defmodule PostHog.FeatureFlagsTest do
  # group only works for Elixir 1.18, can't make it async until then
  use PostHog.Case, async: false, group: PostHog

  @moduletag config: [supervisor_name: PostHog]

  import Mox

  alias PostHog.API
  alias PostHog.FeatureFlags

  setup :setup_supervisor
  setup :verify_on_exit!

  describe "flags/2" do
    test "returns body on success" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end)

      assert {:ok, %{status: 200, body: %{}}} = FeatureFlags.flags(%{distinct_id: "foo"})
    end

    test "sophisticated body" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{
                 distinct_id: "foo",
                 groups: %{group_type: "group_id"}
               }

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} =
               FeatureFlags.flags(%{
                 distinct_id: "foo",
                 groups: %{group_type: "group_id"}
               })
    end

    test "client errors passed as is" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:error, :transport_error}
      end)

      assert {:error, :transport_error} = FeatureFlags.flags("foo")
    end

    test "non-200 is wrapped in error" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 503}}
      end)

      assert {:error,
              %PostHog.UnexpectedResponseError{
                response: %{status: 503},
                message: "Unexpected response"
              }} =
               FeatureFlags.flags(%{distinct_id: "foo"})
    end

    test "unexpected response body" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: "internal server error"}}
      end)

      assert {:error,
              %PostHog.UnexpectedResponseError{
                response: "internal server error",
                message: "Expected response body to have \"flags\" key"
              }} = FeatureFlags.flags(%{distinct_id: "foo"})
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{body: %{"flags" => _}}} =
               FeatureFlags.flags(MyPostHog, %{distinct_id: "foo"})
    end
  end

  describe "flags_for/2" do
    test "returns flags on success" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok, %{status: 200, body: %{"flags" => %{"foo" => %{}}}}}
      end)

      assert {:ok, %{"foo" => %{}}} = FeatureFlags.flags_for("foo")
    end

    test "full request map" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo", personal_properties: %{foo: "bar"}}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} =
               FeatureFlags.flags_for(%{
                 distinct_id: "foo",
                 personal_properties: %{foo: "bar"}
               })
    end

    test "distinct_id is taken from the context if not passed" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} = FeatureFlags.flags_for()
    end

    test "explicit distinct_id preferred over context" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "bar"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{}} = FeatureFlags.flags_for("bar")
    end

    test "missing distinct_Id" do
      assert {:error,
              %PostHog.Error{
                message:
                  "distinct_id is required but wasn't explicitely provided or found in the context"
              }} =
               FeatureFlags.flags_for(nil)
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, %{"example-feature-flag-1" => %{}}} =
               FeatureFlags.flags_for(MyPostHog, "foo")
    end
  end

  describe "check/3" do
    test "returns variant if present" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok,
         %{
           status: 200,
           body: %{"flags" => %{"myflag" => %{"enabled" => true, "variant" => "variant1"}}}
         }}
      end)

      assert {:ok, "variant1"} = FeatureFlags.check("myflag", "foo")
    end

    test "returns true if enabled" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"enabled" => true}}}}}
      end)

      assert {:ok, true} = FeatureFlags.check("myflag", "foo")
    end

    test "returns false otherwise" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{}}}}}
      end)

      assert {:ok, false} = FeatureFlags.check("myflag", "foo")
    end

    test "full request map" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo", personal_properties: %{foo: "bar"}}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} =
               FeatureFlags.check("example-feature-flag-1", %{
                 distinct_id: "foo",
                 personal_properties: %{foo: "bar"}
               })
    end

    test "distinct_id is taken from the context if not passed" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} = FeatureFlags.check("example-feature-flag-1")
    end

    test "explicit distinct_id preferred over context" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "bar"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} = FeatureFlags.check("example-feature-flag-1", "bar")
    end

    test "missing distinct_Id" do
      assert {:error,
              %PostHog.Error{
                message:
                  "distinct_id is required but wasn't explicitely provided or found in the context"
              }} =
               FeatureFlags.check("example-feature-flag-1")
    end

    test "sets feature flag context" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"variant" => "variant1"}}}}}
      end)

      assert {:ok, "variant1"} = FeatureFlags.check("myflag", "foo")
      assert %{"$feature/myflag" => "variant1"} = PostHog.get_context()
    end

    test "publishes $feature_flag_called event " do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"variant" => "variant1"}}}}}
      end)

      assert {:ok, "variant1"} = FeatureFlags.check("myflag", "foo")

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "foo",
                 properties: %{"$feature_flag": "myflag", "$feature_flag_response": "variant1"}
               }
             ] = all_captured()
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert {:ok, true} = FeatureFlags.check(MyPostHog, "example-feature-flag-1", "foo")
    end
  end

  describe "check!/3" do
    test "returns variant if present" do
      expect(API.Mock, :request, fn _client, method, url, opts ->
        assert method == :post
        assert url == "/flags"
        assert opts[:params] == %{v: 2}

        assert opts[:json] == %{
                 distinct_id: "foo"
               }

        {:ok,
         %{
           status: 200,
           body: %{"flags" => %{"myflag" => %{"enabled" => true, "variant" => "variant1"}}}
         }}
      end)

      assert "variant1" = FeatureFlags.check!("myflag", "foo")
    end

    test "returns true if enabled" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"enabled" => true}}}}}
      end)

      assert true = FeatureFlags.check!("myflag", "foo")
    end

    test "returns false otherwise" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{}}}}}
      end)

      assert false == FeatureFlags.check!("myflag", "foo")
    end

    test "full request map" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo", personal_properties: %{foo: "bar"}}

        API.Stub.request(client, method, url, opts)
      end)

      assert true =
               FeatureFlags.check!("example-feature-flag-1", %{
                 distinct_id: "foo",
                 personal_properties: %{foo: "bar"}
               })
    end

    test "distinct_id is taken from the context if not passed" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert true = FeatureFlags.check!("example-feature-flag-1")
    end

    test "explicit distinct_id preferred over context" do
      PostHog.set_context(%{distinct_id: "foo"})

      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "bar"}

        API.Stub.request(client, method, url, opts)
      end)

      assert true = FeatureFlags.check!("example-feature-flag-1", "bar")
    end

    test "missing distinct_id" do
      assert_raise PostHog.Error, fn ->
        FeatureFlags.check!("example-feature-flag-1")
      end
    end

    test "unexpected body shape" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{}}}}
      end)

      assert_raise PostHog.UnexpectedResponseError,
                   "Feature flag example-feature-flag-1 was not found in the response\n\n%{\"flags\" => %{}}",
                   fn ->
                     FeatureFlags.check!("example-feature-flag-1", "bar")
                   end
    end

    test "sets feature flag context" do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"variant" => "variant1"}}}}}
      end)

      assert "variant1" = FeatureFlags.check!("myflag", "foo")
      assert %{"$feature/myflag" => "variant1"} = PostHog.get_context()
    end

    test "publishes $feature_flag_called event " do
      expect(API.Mock, :request, fn _client, _method, _url, _opts ->
        {:ok, %{status: 200, body: %{"flags" => %{"myflag" => %{"variant" => "variant1"}}}}}
      end)

      assert "variant1" = FeatureFlags.check!("myflag", "foo")

      assert [
               %{
                 event: "$feature_flag_called",
                 distinct_id: "foo",
                 properties: %{"$feature_flag": "myflag", "$feature_flag_response": "variant1"}
               }
             ] = all_captured()
    end

    @tag config: [supervisor_name: MyPostHog]
    test "custom PostHog instance" do
      expect(API.Mock, :request, fn client, method, url, opts ->
        assert opts[:json] == %{distinct_id: "foo"}

        API.Stub.request(client, method, url, opts)
      end)

      assert true = FeatureFlags.check!(MyPostHog, "example-feature-flag-1", "foo")
    end
  end
end
