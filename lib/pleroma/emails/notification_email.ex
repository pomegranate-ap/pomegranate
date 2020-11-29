defmodule Pleroma.Emails.NotificationEmail do
  use Phoenix.Swoosh, view: Pleroma.Web.EmailView, layout: {Pleroma.Web.LayoutView, :email}

  def notify(%{type: "mention", user: user, activity: activity}) do
    from = Pleroma.User.get_by_ap_id(activity.actor)

    from_url = Pleroma.Web.Endpoint.url() <> "/users/" <> from.id
    activity_url = Pleroma.Web.Endpoint.url() <> "/notice/" <> activity.id

    html_body = """

    <p><a href="#{from_url}">@#{from.nickname}</a> mentioned you in <a href="#{activity_url}">#{
      activity_url
    }</a></p>
    """

    new()
    |> to(Pleroma.Emails.UserEmail.recipient(user))
    |> from(Pleroma.Config.Helpers.sender())
    |> subject("New mention at #{Pleroma.Config.Helpers.instance_name()}")
    |> html_body(html_body)
  end

  def notify(_), do: :ok
end
