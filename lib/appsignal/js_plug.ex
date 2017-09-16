if Appsignal.plug? do
  require Logger
  defmodule Appsignal.JSPlug do
    import Plug.Conn
    use Appsignal.Config

    @transaction Application.get_env(:appsignal, :appsignal_transaction, Appsignal.Transaction)

    @moduledoc """
    Plug handler for JavaScript exception requests
    """

    def init(_) do
      Logger.debug("Initializing Appsignal.JSPlug")
    end

    def call(%Plug.Conn{request_path: "/appsignal_error_catcher", method: "POST"} = conn, _) do
      record_transaction(conn)
      send_resp(conn, 200, "")
    end
    def call(conn, _), do: conn

    defp record_transaction(conn) do
      c = conn |> fetch_session
      %{
        "name" => name,
        "message" => message,
        "backtrace" => backtrace,
        "action" => action,
        "environment" => environment,
      } = params = c.params

      transaction =
        Appsignal.Transaction.start(@transaction.generate_id, :frontend)
        |> @transaction.set_action(action)
        |> @transaction.set_error(name, message, backtrace)
      case @transaction.finish(transaction) do
        :sample ->
          transaction
          |> @transaction.set_sample_data("environment", environment)

          if Map.has_key?(params, "params") do
            {:ok, p} = Map.fetch(params, "params")
            @transaction.set_sample_data(transaction, "params", p)
          end

          if !config()[:skip_session_data] and c.private[:plug_session_fetch] == :done do
            @transaction.set_sample_data(
              transaction, "session_data", c.private[:plug_session]
            )
          end
      end
      :ok = @transaction.complete(transaction)
    end
  end
end
