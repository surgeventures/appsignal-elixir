if Appsignal.plug? do
  require Logger
  defmodule Appsignal.JSPlug do
    import Plug.Conn

    @transaction Application.get_env(:appsignal, :appsignal_transaction, Appsignal.Transaction)

    @moduledoc """
    Plug handler for JavaScript exception requests
    """

    def init(_) do
      Logger.debug("Initializing Appsignal.JSPlug")
    end

    def call(%Plug.Conn{request_path: "/appsignal_error_catcher", method: "POST"} = conn, _) do
      IO.inspect conn
      record_transaction(conn)

      send_resp(conn, 200, "")
    end

    def call(conn, _), do: conn

    defp record_transaction(conn) do
      %{
        "name" => name,
        "message" => message,
        "backtrace" => backtrace,
        "action" => action,
        "environment" => environment
      } = conn.params

      transaction =
        Appsignal.Transaction.start(@transaction.generate_id, :frontend)
        |> @transaction.set_action(action)
        |> @transaction.set_error(name, message, backtrace)
      case @transaction.finish(transaction) do
        :sample ->
          transaction
          |> @transaction.set_sample_data(
            "environment", environment
          )
          |> @transaction.set_sample_data(
            "params", conn.params
          )
          # |> @transaction.set_sample_data(
          #   "session_data", conn.params
          # )
      end
      :ok = @transaction.complete(transaction)
    end
  end
end
