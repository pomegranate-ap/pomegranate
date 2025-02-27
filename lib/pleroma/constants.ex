# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Constants do
  use Const

  const(as_public, do: "https://www.w3.org/ns/activitystreams#Public")

  const(object_internal_fields,
    do: [
      "reactions",
      "reaction_count",
      "likes",
      "like_count",
      "announcements",
      "announcement_count",
      "emoji",
      "context_id",
      "deleted_activity_id",
      "pleroma_internal"
    ]
  )

  const(static_only_files,
    do:
      ~w(index.html robots.txt static static-fe finmoji emoji packs sounds images instance sw.js sw-pleroma.js favicon.png schemas doc embed.js embed.css)
  )

  def as_local_public, do: Pleroma.Web.base_url() <> "/#Public"
end
