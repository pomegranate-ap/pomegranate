defmodule Pleroma.BBS.Handler do
  @moduledoc """
  An example implementation of `Sshd.ShellHandler`, implementing a very simple
  Read-Eval-Loop, that does nothing.
  """
  use Sshd.ShellHandler
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.ActivityPub.ActivityPub

  def on_shell(username, _pubkey, _ip, _port) do
    :ok = IO.puts "Welcome to #{Pleroma.Config.get([:instance, :name])}!"
    user = Pleroma.User.get_by_nickname(to_string(username))
    Logger.debug("#{inspect user}")
    loop(run_state([user: user]))
  end

  def on_connect(username, ip, port, method) do
    Logger.debug fn ->
      """
      Incoming SSH shell #{inspect self()} requested for #{username} from #{inspect ip}:#{inspect port} using #{inspect method}
      """
    end
  end

  def on_disconnect(username, ip, port) do
    Logger.debug fn ->
      "Disconnecting SSH shell for #{username} from #{inspect ip}:#{inspect port}"
    end
  end

  defp loop(state) do
    self_pid = self()
    counter  = state.counter
    prefix   = state.prefix
    user     = state.user

    input = spawn(fn -> io_get(self_pid, prefix, counter, user.nickname) end)
    wait_input state, input
  end

  def puts_activity(activity) do
    status = Pleroma.Web.MastodonAPI.StatusView.render("status.json", %{activity: activity})
    IO.puts("#{status.id} by #{status.account.display_name} (#{status.account.acct}):")
    IO.puts(HtmlSanitizeEx.strip_tags(status.content))
    IO.puts("")
  end

  def handle_command(state, "help") do
    IO.puts("Available commands:")
    IO.puts("help - This help")
    IO.puts("home - Show the home timeline")
    IO.puts("p <text> - Post the given text")
    IO.puts("quit - Quit")

    state
  end

  def handle_command(%{user: user} = state, "p " <> text) do
    text = String.trim(text)

    with {:ok, _activity} <- CommonAPI.post(user, %{"status" => text}) do
      IO.puts("Posted!")
    else
      _e -> IO.puts("Could not post...")
    end
    state
  end

  def handle_command(state, "home") do
    user = state.user
    params =
      %{}
      |> Map.put("type", ["Create", "Announce"])
      |> Map.put("blocking_user", user)
      |> Map.put("muting_user", user)
      |> Map.put("user", user)

    activities =
      [user.ap_id | user.following]
      |> ActivityPub.fetch_activities(params)
      |> ActivityPub.contain_timeline(user)
      |> Enum.reverse()

    Enum.each(activities, fn (activity) ->
      puts_activity(activity)
    end)

    state
  end

  def handle_command(_state, command) do
    IO.puts("Unknown command '#{command}'")
  end

  defp wait_input(state, input) do
    receive do
      {:input, ^input, "quit\n"} ->
        IO.puts "Exiting..."

      {:input, ^input, code} when is_binary(code) ->
        code = String.trim(code)

        handle_command(state, code)

        loop(%{state | counter: state.counter + 1})

      {:error, :interrupted} ->
        IO.puts "Caught Ctrl+C..."
        loop(%{state | counter: state.counter + 1})

      {:input, ^input, msg} ->
        :ok = Logger.warn "received unknown message: #{inspect msg}"
        loop(%{state | counter: state.counter + 1})
    end
  end

  defp run_state(opts) do
    %{prefix: "pleroma", counter: 1, user: opts[:user]}
  end

  defp io_get(pid, prefix, counter, username) do
    prompt = prompt(prefix, counter, username)
    send pid, {:input, self(), IO.gets(:stdio, prompt)}
  end

  defp prompt(prefix, counter, username) do
    prompt = "#{username}@#{prefix}:#{counter}>"
    prompt <> " "
  end
end
