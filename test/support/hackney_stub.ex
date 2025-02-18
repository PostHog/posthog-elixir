defmodule HackneyStub do
  @fixtures_dir Path.join(__DIR__, "fixtures")

  def post("https://app.posthog.com/decide?v=3", _headers, _body, _opts) do
    {:ok, 200, json_fixture!("decide.json"), "decide"}
  end

  def body("decide") do
    {:ok, json_fixture!("decide.json")}
  end

  defp json_fixture!(fixture) do
    @fixtures_dir
    |> Path.join(fixture)
    |> File.read!()
  end
end
