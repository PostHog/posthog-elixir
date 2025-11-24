defmodule PostHog.API.Stub do
  @moduledoc false
  @behaviour PostHog.API.Client

  @impl PostHog.API.Client
  def client(_api_key, _api_host) do
    %PostHog.API.Client{client: :stub_client, module: PostHog.API.Mock}
  end

  @impl PostHog.API.Client
  def request(_client, :post, "/batch", _opts) do
    {:ok, %{status: 200, body: %{"status" => "Ok"}}}
  end

  def request(_client, :post, "/flags", _opts) do
    {:ok,
     %{
       status: 200,
       body: %{
         "errorsWhileComputingFlags" => false,
         "flags" => %{
           "example-feature-flag-1" => %{
             "enabled" => true,
             "key" => "example-feature-flag-1",
             "metadata" => %{
               "description" => nil,
               "id" => 154_429,
               "payload" => nil,
               "version" => 4
             },
             "reason" => %{
               "code" => "condition_match",
               "condition_index" => 0,
               "description" => "Matched condition set 1"
             },
             "variant" => nil
           }
         },
         "requestId" => "0d23f243-399a-4904-b1a8-ec2037834b72",
         "evaluatedAt" => 1_234_567_890
       }
     }}
  end
end
