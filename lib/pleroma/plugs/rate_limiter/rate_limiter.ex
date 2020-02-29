# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Plugs.RateLimiter do
  @moduledoc """

  ## Configuration

  A keyword list of rate limiters where a key is a limiter name and value is the limiter configuration.
  The basic configuration is a tuple where:

  * The first element: `scale` (Integer). The time scale in milliseconds.
  * The second element: `limit` (Integer). How many requests to limit in the time scale provided.

  It is also possible to have different limits for unauthenticated and authenticated users: the keyword value must be a
  list of two tuples where the first one is a config for unauthenticated users and the second one is for authenticated.

  To disable a limiter set its value to `nil`.

  ### Example

      config :pleroma, :rate_limit,
        one: {1000, 10},
        two: [{10_000, 10}, {10_000, 50}],
        foobar: nil

  Here we have three limiters:

  * `one` which is not over 10req/1s
  * `two` which has two limits: 10req/10s for unauthenticated users and 50req/10s for authenticated users
  * `foobar` which is disabled

  ## Usage

  AllowedSyntax:

      plug(Pleroma.Plugs.RateLimiter, name: :limiter_name)
      plug(Pleroma.Plugs.RateLimiter, options)   # :name is a required option

  Allowed options:

      * `name` required, always used to fetch the limit values from the config
      * `bucket_name` overrides name for counting purposes (e.g. to have a separate limit for a set of actions)
      * `params` appends values of specified request params (e.g. ["id"]) to bucket name

  Inside a controller:

      plug(Pleroma.Plugs.RateLimiter, [name: :one] when action == :one)
      plug(Pleroma.Plugs.RateLimiter, [name: :two] when action in [:two, :three])

      plug(
        Pleroma.Plugs.RateLimiter,
        [name: :status_id_action, bucket_name: "status_id_action:fav_unfav", params: ["id"]]
        when action in ~w(fav_status unfav_status)a
      )

  or inside a router pipeline:

      pipeline :api do
        ...
        plug(Pleroma.Plugs.RateLimiter, name: :one)
        ...
      end
  """
  import Pleroma.Web.TranslationHelpers
  import Plug.Conn

  alias Pleroma.Config
  alias Pleroma.Plugs.RateLimiter.LimiterSupervisor
  alias Pleroma.User

  require Logger

  @doc false
  def init(plug_opts) do
    with limiter_name when is_atom(limiter_name) <- plug_opts[:name] do
      bucket_name_root = Keyword.get(plug_opts, :bucket_name, limiter_name)

      %{
        name: bucket_name_root,
        opts: plug_opts
      }
    else
      _ -> nil
    end
  end

  def call(conn, nil), do: conn

  def call(conn, action_static_settings) do
    if disabled?() do
      handle_disabled(conn)
    else
      action_settings = action_settings(action_static_settings)
      handle(conn, action_settings)
    end
  end

  defp handle_disabled(conn) do
    if Config.get(:env) == :prod do
      Logger.warn("Rate limiter is disabled for localhost/socket")
    end

    conn
  end

  defp handle(conn, nil), do: conn

  defp handle(conn, action_settings) do
    action_settings
    |> incorporate_conn_info(conn)
    |> check_rate()
    |> case do
      {:ok, _count} ->
        conn

      {:error, _count} ->
        render_throttled_error(conn)
    end
  end

  def disabled? do
    localhost_or_socket =
      Config.get([Pleroma.Web.Endpoint, :http, :ip])
      |> Tuple.to_list()
      |> Enum.join(".")
      |> String.match?(~r/^local|^127.0.0.1/)

    remote_ip_disabled = not Config.get([Pleroma.Plugs.RemoteIp, :enabled])

    localhost_or_socket and remote_ip_disabled
  end

  @inspect_bucket_not_found {:error, :not_found}

  def inspect_bucket(conn, bucket_name_root, %{name: _} = action_static_settings) do
    action_settings =
      action_static_settings
      |> action_settings()
      |> incorporate_conn_info(conn)

    bucket_name = make_bucket_name(%{action_settings | name: bucket_name_root})
    key_name = make_key_name(action_settings)
    limit = get_limits(action_settings)

    case Cachex.get(bucket_name, key_name) do
      {:error, :no_cache} ->
        @inspect_bucket_not_found

      {:ok, nil} ->
        {0, limit}

      {:ok, value} ->
        {value, limit - value}
    end
  end

  def inspect_bucket(_conn, _bucket_name_root, _action_static_settings),
    do: @inspect_bucket_not_found

  def action_settings(nil), do: nil

  def action_settings(%{opts: opts} = action_static_settings) do
    with limits when not is_nil(limits) <- Config.get([:rate_limit, opts[:name]]) do
      Map.put(action_static_settings, :limits, limits)
    else
      _ -> nil
    end
  end

  defp check_rate(action_settings) do
    bucket_name = make_bucket_name(action_settings)
    key_name = make_key_name(action_settings)
    limit = get_limits(action_settings)

    case Cachex.get_and_update(bucket_name, key_name, &increment_value(&1, limit)) do
      {:commit, value} ->
        {:ok, value}

      {:ignore, value} ->
        {:error, value}

      {:error, :no_cache} ->
        initialize_buckets(action_settings)
        check_rate(action_settings)
    end
  end

  defp increment_value(nil, _limit), do: {:commit, 1}

  defp increment_value(val, limit) when val >= limit, do: {:ignore, val}

  defp increment_value(val, _limit), do: {:commit, val + 1}

  defp incorporate_conn_info(action_settings, %{
         assigns: %{user: %User{id: user_id}},
         params: params
       }) do
    Map.merge(action_settings, %{
      mode: :user,
      conn_params: params,
      conn_info: "#{user_id}"
    })
  end

  defp incorporate_conn_info(action_settings, %{params: params} = conn) do
    Map.merge(action_settings, %{
      mode: :anon,
      conn_params: params,
      conn_info: "#{ip(conn)}"
    })
  end

  defp ip(%{remote_ip: remote_ip}) do
    remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp render_throttled_error(conn) do
    conn
    |> render_error(:too_many_requests, "Throttled")
    |> halt()
  end

  defp make_key_name(action_settings) do
    ""
    |> attach_selected_params(action_settings)
    |> attach_identity(action_settings)
  end

  defp get_scale(_, {scale, _}), do: scale

  defp get_scale(:anon, [{scale, _}, {_, _}]), do: scale

  defp get_scale(:user, [{_, _}, {scale, _}]), do: scale

  defp get_limits(%{limits: {_scale, limit}}), do: limit

  defp get_limits(%{mode: :user, limits: [_, {_, limit}]}), do: limit

  defp get_limits(%{limits: [{_, limit}, _]}), do: limit

  defp make_bucket_name(%{mode: :user, name: bucket_name_root}),
    do: user_bucket_name(bucket_name_root)

  defp make_bucket_name(%{mode: :anon, name: bucket_name_root}),
    do: anon_bucket_name(bucket_name_root)

  defp attach_selected_params(input, %{conn_params: conn_params, opts: action_static_settings}) do
    params_string =
      action_static_settings
      |> Keyword.get(:params, [])
      |> Enum.sort()
      |> Enum.map(&Map.get(conn_params, &1, ""))
      |> Enum.join(":")

    [input, params_string]
    |> Enum.join(":")
    |> String.replace_leading(":", "")
  end

  defp initialize_buckets(%{name: _name, limits: nil}), do: :ok

  defp initialize_buckets(%{name: name, limits: limits}) do
    LimiterSupervisor.add_limiter(anon_bucket_name(name), get_scale(:anon, limits))
    LimiterSupervisor.add_limiter(user_bucket_name(name), get_scale(:user, limits))
  end

  defp attach_identity(base, %{mode: :user, conn_info: conn_info}),
    do: "user:#{base}:#{conn_info}"

  defp attach_identity(base, %{mode: :anon, conn_info: conn_info}),
    do: "ip:#{base}:#{conn_info}"

  defp user_bucket_name(bucket_name_root), do: "user:#{bucket_name_root}" |> String.to_atom()
  defp anon_bucket_name(bucket_name_root), do: "anon:#{bucket_name_root}" |> String.to_atom()
end
