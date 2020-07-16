# Notes and guidelines for Pleroma developers

## Authentication & Authorization

### OAuth token-based authentication & authorization

* Pleroma supports hierarchical OAuth scopes, just like Mastodon but with added granularity of admin scopes. For a reference, see [Mastodon OAuth scopes](https://docs.joinmastodon.org/api/oauth-scopes/).

* It is important to either define OAuth scope restrictions or explicitly mark OAuth scope check as skipped, for every controller action. To define scopes, call `plug(Pleroma.Web.Plugs.OAuthScopesPlug, %{scopes: [...]})`. To explicitly set OAuth scopes check skipped, call `plug(:skip_plug, Pleroma.Web.Plugs.OAuthScopesPlug <when ...>)`.

* In controllers, `use Pleroma.Web, :controller` will result in `action/2` (see `Pleroma.Web.controller/0` for definition) be called prior to actual controller action, and it'll perform security / privacy checks before passing control to actual controller action.

  For routes with `:authenticated_api` pipeline, authentication & authorization are expected, thus `OAuthScopesPlug` will be run unless explicitly skipped (also `EnsureAuthenticatedPlug` will be executed immediately before action even if there was an early run to give an early error, since `OAuthScopesPlug` supports `:proceed_unauthenticated` option, and other plugs may support similar options as well).

  For `:api` pipeline routes, it'll be verified whether `OAuthScopesPlug` was called or explicitly skipped, and if it was not then auth information will be dropped for request. Then `EnsurePublicOrAuthenticatedPlug` will be called to ensure that either the instance is not private or user is authenticated (unless explicitly skipped). Such automated checks help to prevent human errors and result in higher security / privacy for users.

### [HTTP Basic Authentication](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Authorization)

* With HTTP Basic Auth, OAuth scopes check is _not_ performed for any action (since password is provided during the auth, requester is able to obtain a token with full permissions anyways). `Pleroma.Web.Plugs.AuthenticationPlug` and `Pleroma.Web.Plugs.LegacyAuthenticationPlug` both call `Pleroma.Web.Plugs.OAuthScopesPlug.skip_plug(conn)` when password is provided.

### Auth-related configuration, OAuth consumer mode etc.

See `Authentication` section of [the configuration cheatsheet](configuration/cheatsheet.md#authentication).

## MRF policies descriptions

If MRF policy depends on config, it can be added into MRF tab to adminFE by adding `config_description/0` method, which returns map with special structure.

Example:

```elixir
%{
      key: :mrf_activity_expiration,
      related_policy: "Pleroma.Web.ActivityPub.MRF.ActivityExpirationPolicy",
      label: "MRF Activity Expiration Policy",
      description: "Adds automatic expiration to all local activities",
      children: [
        %{
          key: :days,
          type: :integer,
          description: "Default global expiration time for all local activities (in days)",
          suggestions: [90, 365]
        }
      ]
    }
```

## Config versioning

Database configuration supports simple versioning. Every change (list of changes or only one change) through adminFE creates new version with backup from config table. It is possible to do rollback on N steps (1 by default). Rollback will recreate `config` table from backup.

**IMPORTANT** Destructive operations with `Pleroma.ConfigDB` and `Pleroma.Config.Version` must be processed through `Pleroma.Config.Versioning` module for correct versioning work, especially migration changes.

Example:

* new config setting is added directly using `Pleroma.ConfigDB` module
* user is doing rollback and setting is lost

### Creating new version

Creating new version is done with `Pleroma.Config.Versioning.new_version/1`, which accepts list of changes. Changes can include adding/updating/deleting operations in `config` table at the same time.

Process of creating new version:

* saving config changes in `config` table
* saving new version with current configs
  * `backup` - keyword with all configs from `config` table (binary)
  * `current` - flag, which marks current version (boolean)

### Version rollback

Version control also supports a simple N steps back mechanism.

Rollback process:

* cleaning `config` table
* splitting `backup` field into separate settings and inserting them into `config` table
* removing subsequent versions

### Config migrations

Sometimes it becomes necessary to make changes to the configuration, which can be stored in the user's database. Config versioning makes this process more complicated, as we also must update this setting in versions backups.

Versioning module contains two functions for migrations:

* `Pleroma.Config.Versioning.migrate_namespace/2` - for simple renaming, e.g. group or key of the setting must be renamed.
* `Pleroma.Config.Versioning.migrate_configs_and_versions/2` - abstract function for more complex migrations. Accepts two functions, the first one to make changes with configs, another to make changes with version backups.
