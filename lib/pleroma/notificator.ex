defmodule Pleroma.Notificator do
  @callback send(Pleroma.Notification.t()) :: :ok | :error

  def send(notification) do
    config = Pleroma.Config.get(__MODULE__)

    notification = Pleroma.Repo.preload(notification, [:user])

    if config[:enabled] do
      Enum.each(config[:mods], & &1.send(notification))
    end
  end
end
