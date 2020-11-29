defmodule Pleroma.Notificators.EmailNotificator do
  @behaviour Pleroma.Notificator

  @impl true
  def send(%{type: type, user: user} = notification) do
    if type in user.email_notifications["notifications"] do
      do_send(notification)
    end

    :ok
  end

  def send(_, _), do: :ok

  defp do_send(notification) do
    notification
    |> Pleroma.Emails.NotificationEmail.notify()
    |> Pleroma.Emails.Mailer.deliver()
  end
end
