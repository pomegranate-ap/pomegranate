# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AnnounceValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility

  import Ecto.Changeset
  import Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  require Pleroma.Constants

  @primary_key false

  embedded_schema do
    field(:id, ObjectValidators.ObjectID, primary_key: true)
    field(:type, :string)
    field(:object, ObjectValidators.ObjectID)
    field(:actor, ObjectValidators.ObjectID)
    field(:context, :string, autogenerate: {Utils, :generate_context_id, []})
    field(:to, ObjectValidators.Recipients, default: [])
    field(:cc, ObjectValidators.Recipients, default: [])
    field(:published, ObjectValidators.DateTime)
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  def cast_data(data) do
    %__MODULE__{}
    |> changeset(data)
  end

  def changeset(struct, data) do
    struct
    |> cast(data, __schema__(:fields))
    |> fix_after_cast()
  end

  def fix_after_cast(cng) do
    cng
  end

  def validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Announce"])
    |> validate_required([:id, :type, :object, :actor, :to, :cc])
    |> validate_actor_presence()
    |> validate_object_presence()
    |> validate_existing_announce()
    |> validate_announcable()
  end

  def validate_announcable(cng) do
    with actor when is_binary(actor) <- get_field(cng, :actor),
         object when is_binary(object) <- get_field(cng, :object),
         %User{} = actor <- User.get_cached_by_ap_id(actor),
         %Object{} = object <- Object.get_cached_by_ap_id(object),
         false <- Visibility.is_public?(object) do
      same_actor = object.data["actor"] == actor.ap_id
      recipients = get_field(cng, :to) ++ get_field(cng, :cc)
      local_public = Pleroma.Constants.as_local_public()

      is_public =
        Enum.member?(recipients, Pleroma.Constants.as_public()) or
          Enum.member?(recipients, local_public)

      cond do
        same_actor && is_public ->
          cng
          |> add_error(:actor, "can not announce this object publicly")

        !same_actor ->
          cng
          |> add_error(:actor, "can not announce this object")

        true ->
          cng
      end
    else
      _ -> cng
    end
  end

  def validate_existing_announce(cng) do
    actor = get_field(cng, :actor)
    object = get_field(cng, :object)

    if actor && object && Utils.get_existing_announce(actor, %{data: %{"id" => object}}) do
      cng
      |> add_error(:actor, "already announced this object")
      |> add_error(:object, "already announced by this actor")
    else
      cng
    end
  end
end
