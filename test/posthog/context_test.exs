defmodule PostHog.ContextTest do
  use ExUnit.Case, async: true

  alias PostHog.Context

  test "sets context for specific scope" do
    assert :ok = Context.set(PostHog, "$exception", %{foo: "bar"})
    assert [__posthog__: %{PostHog => %{"$exception" => %{foo: "bar"}}}] = Logger.metadata()
  end

  test "context is merged" do
    Context.set(PostHog, "$exception", %{foo: "bar"})
    Context.set(PostHog, "$exception", %{foo: "baz", eggs: "spam"})

    assert [__posthog__: %{PostHog => %{"$exception" => %{eggs: "spam", foo: "baz"}}}] =
             Logger.metadata()
  end

  test "but not deep merged" do
    Context.set(PostHog, "$exception", %{foo: %{eggs: "spam"}})
    Context.set(PostHog, "$exception", %{foo: %{bar: "baz"}})

    assert [__posthog__: %{PostHog => %{"$exception" => %{foo: %{bar: "baz"}}}}] =
             Logger.metadata()
  end

  test "multiple scopes" do
    Context.set(PostHog, :all, %{foo: "bar"})
    Context.set(MyPostHog, "$exception", %{foo: "baz"})
    Context.set(:all, :all, %{hello: "world"})

    assert [
             __posthog__: %{
               PostHog => %{all: %{foo: "bar"}},
               MyPostHog => %{"$exception" => %{foo: "baz"}},
               all: %{all: %{hello: "world"}}
             }
           ] = Logger.metadata()
  end

  test "get/0 retrieves context with scope + all" do
    Context.set(PostHog, :all, %{foo: "bar"})
    Context.set(MyPostHog, "$exception", %{foo: "baz"})
    Context.set(:all, :all, %{hello: "world"})
    Logger.metadata(foo: "baz")

    assert Context.get(PostHog, "$exception") == %{foo: "bar", hello: "world"}
    assert Context.get(MyPostHog, "$exception") == %{foo: "baz", hello: "world"}
    assert Context.get(MyPostHog, "$exception_list") == %{hello: "world"}
    assert Context.get(FooBar, "$exception") == %{hello: "world"}
  end

  test "in case of overlapping keys prefer more specific scope" do
    Context.set(PostHog, :all, %{foo: 1})
    Context.set(PostHog, "$exception", %{foo: 2})
    Context.set(:all, :all, %{foo: 3})
    Context.set(:all, "$exception", %{foo: 4})

    assert %{foo: 2} = Context.get(PostHog, "$exception")
    assert %{foo: 4} = Context.get(:all, "$exception")
  end
end
