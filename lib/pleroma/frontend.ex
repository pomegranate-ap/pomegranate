# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Frontend do
  @type frontend_kind :: :primary

  def get_config(frontend \\ :primary)

  def get_config(:primary) do
    primary_fe_config = Pleroma.Config.get([:frontends, :primary], %{"name" => "pleroma"})
    static_enabled? = Pleroma.Config.get([:frontends, :static], false)

    {config, controller} =
      if primary_fe_config["name"] == "none" do
        {%{}, Pleroma.Web.Frontend.HeadlessController}
      else
        {primary_fe_config,
         Module.concat([
           Pleroma.Web.Frontend,
           String.capitalize(primary_fe_config["name"]) <> "Controller"
         ])}
      end

    %{"config" => config, "controller" => controller, "static" => static_enabled?}
  end

  @spec file_path(String.t(), frontend_kind()) :: {:ok, String.t()} | {:error, String.t()}
  def file_path(file, kind \\ :primary) do
    config = get_config(kind)

    instance_static_dir = Pleroma.Config.get([:instance, :static_dir], "instance/static")

    frontend_path =
      case config["config"] do
        %{"name" => name, "ref" => ref} ->
          Path.join([instance_static_dir, "frontends", name, ref, file])

        _ ->
          false
      end

    instance_path = Path.join([instance_static_dir, file])
    priv_path = Application.app_dir(:pleroma, ["priv", "static", file])

    cond do
      File.exists?(instance_path) ->
        {:ok, instance_path}

      frontend_path && File.exists?(frontend_path) ->
        {:ok, frontend_path}

      File.exists?(priv_path) ->
        {:ok, priv_path}

      true ->
        {:error,
         "File #{file} not found in #{inspect([instance_path, frontend_path, priv_path])}"}
    end
  end
end
