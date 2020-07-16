# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Mix.Tasks.Pleroma.Config do
  use Mix.Task

  import Mix.Pleroma

  alias Pleroma.ConfigDB
  alias Pleroma.Repo

  @shortdoc "Manages the location of the config"
  @moduledoc File.read!("docs/administration/CLI_tasks/config.md")

  def run(["migrate_to_db" | options]) do
    start_pleroma()

    {opts, _} = OptionParser.parse!(options, strict: [config: :string])

    migrate_to_db(opts)
  end

  def run(["migrate_from_db" | options]) do
    start_pleroma()

    {opts, _} =
      OptionParser.parse!(options,
        strict: [env: :string, delete: :boolean],
        aliases: [d: :delete]
      )

    migrate_from_db(opts)
  end

  def run(["rollback" | options]) do
    start_pleroma()
    {opts, _} = OptionParser.parse!(options, strict: [steps: :integer], aliases: [s: :steps])

    do_rollback(opts)
  end

  defp do_rollback(opts) do
    if Pleroma.Config.get(:configurable_from_database) do
      steps = opts[:steps] || 1

      case Pleroma.Config.Versioning.rollback(steps) do
        {:ok, _} ->
          shell_info("Success rollback")

        {:error, :no_current_version} ->
          shell_error("No version to rollback")

        {:error, :rollback_not_possible} ->
          shell_error("Rollback not possible. Incorrect steps value.")

        {:error, _, _, _} ->
          shell_error("Problem with backup. Rollback not possible.")

        error ->
          shell_error("error occuried: #{inspect(error)}")
      end
    else
      operation_error("Config rollback")
    end
  end

  defp migrate_to_db(opts) do
    with true <- Pleroma.Config.get(:configurable_from_database),
         :ok <- Pleroma.Config.DeprecationWarnings.warn() do
      config_file = opts[:config] || Pleroma.Application.config_path()

      if File.exists?(config_file) do
        do_migrate_to_db(config_file)
      else
        shell_info("To migrate settings, you must define custom settings in #{config_file}.")
      end
    else
      :error -> deprecation_error()
      _ -> operation_error()
    end
  end

  defp do_migrate_to_db(config_file) do
    shell_info("Migrating settings from file: #{Path.expand(config_file)}")
    {:ok, _} = Pleroma.Config.Versioning.migrate(config_file)
    shell_info("Settings migrated.")
  end

  defp migrate_from_db(opts) do
    if Pleroma.Config.get(:configurable_from_database) do
      env = opts[:env] || Pleroma.Config.get(:env)

      config_path =
        if Pleroma.Config.get(:release) do
          :config_path
          |> Pleroma.Config.get()
          |> Path.dirname()
        else
          "config"
        end
        |> Path.join("#{env}.exported_from_db.secret.exs")

      file = File.open!(config_path, [:write, :utf8])

      IO.write(file, Pleroma.Config.Loader.config_header())

      ConfigDB
      |> Repo.all()
      |> Enum.each(&write_and_delete(&1, file, opts[:delete]))

      :ok = File.close(file)
      System.cmd("mix", ["format", config_path])

      shell_info(
        "Database configuration settings have been exported to config/#{env}.exported_from_db.secret.exs"
      )
    else
      operation_error()
    end
  end

  defp operation_error(operation \\ "Migration") do
    shell_error(
      "#{operation} is not allowed in config. You can change this behavior by setting `config :pleroma, configurable_from_database: true`"
    )
  end

  defp deprecation_error do
    shell_error("Migration is not allowed until all deprecation warnings have been resolved.")
  end

  defp write_and_delete(config, file, delete?) do
    config
    |> write(file)
    |> delete(delete?)
  end

  defp write(config, file) do
    value = inspect(config.value, limit: :infinity)

    IO.write(file, "config #{inspect(config.group)}, #{inspect(config.key)}, #{value}\r\n\r\n")

    config
  end

  defp delete(config, true) do
    {:ok, _} = Repo.delete(config)
    shell_info("#{config.key} deleted from DB.")
  end

  defp delete(_config, _), do: :ok
end
