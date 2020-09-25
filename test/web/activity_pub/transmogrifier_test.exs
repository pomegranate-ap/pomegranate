# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.TransmogrifierTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Tests.ObanHelpers
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.AdminAPI.AccountView
  alias Pleroma.Web.CommonAPI

  import Mock
  import Pleroma.Factory
  import ExUnit.CaptureLog

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  setup do: clear_config([:instance, :max_remote_account_fields])

  describe "handle_incoming" do
    test "it works for incoming unfollows with an existing follow" do
      user = insert(:user)

      follow_data =
        File.read!("test/fixtures/mastodon-follow-activity.json")
        |> Poison.decode!()
        |> Map.put("object", user.ap_id)

      {:ok, %Activity{data: _, local: false}} = Transmogrifier.handle_incoming(follow_data)

      data =
        File.read!("test/fixtures/mastodon-unfollow-activity.json")
        |> Poison.decode!()
        |> Map.put("object", follow_data)

      {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["type"] == "Undo"
      assert data["object"]["type"] == "Follow"
      assert data["object"]["object"] == user.ap_id
      assert data["actor"] == "http://mastodon.example.org/users/admin"

      refute User.following?(User.get_cached_by_ap_id(data["actor"]), user)
    end

    test "it accepts Flag activities" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "test post"})
      object = Object.normalize(activity)

      note_obj = %{
        "type" => "Note",
        "id" => activity.data["id"],
        "content" => "test post",
        "published" => object.data["published"],
        "actor" => AccountView.render("show.json", %{user: user, skip_visibility_check: true})
      }

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "cc" => [user.ap_id],
        "object" => [user.ap_id, activity.data["id"]],
        "type" => "Flag",
        "content" => "blocked AND reported!!!",
        "actor" => other_user.ap_id
      }

      assert {:ok, activity} = Transmogrifier.handle_incoming(message)

      assert activity.data["object"] == [user.ap_id, note_obj]
      assert activity.data["content"] == "blocked AND reported!!!"
      assert activity.data["actor"] == other_user.ap_id
      assert activity.data["cc"] == [user.ap_id]
    end

    test "it accepts Move activities" do
      old_user = insert(:user)
      new_user = insert(:user)

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Move",
        "actor" => old_user.ap_id,
        "object" => old_user.ap_id,
        "target" => new_user.ap_id
      }

      assert :error = Transmogrifier.handle_incoming(message)

      {:ok, _new_user} = User.update_and_set_cache(new_user, %{also_known_as: [old_user.ap_id]})

      assert {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(message)
      assert activity.actor == old_user.ap_id
      assert activity.data["actor"] == old_user.ap_id
      assert activity.data["object"] == old_user.ap_id
      assert activity.data["target"] == new_user.ap_id
      assert activity.data["type"] == "Move"
    end
  end

  describe "prepare outgoing" do
    test "it inlines private announced objects" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "hey", visibility: "private"})

      {:ok, announce_activity} = CommonAPI.repeat(activity.id, user)

      {:ok, modified} = Transmogrifier.prepare_outgoing(announce_activity.data)

      assert modified["object"]["content"] == "hey"
      assert modified["object"]["actor"] == modified["object"]["attributedTo"]
    end

    test "it turns mentions into tags" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, activity} =
        CommonAPI.post(user, %{status: "hey, @#{other_user.nickname}, how are ya? #2hu"})

      with_mock Pleroma.Notification,
        get_notified_from_activity: fn _, _ -> [] end do
        {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

        object = modified["object"]

        expected_mention = %{
          "href" => other_user.ap_id,
          "name" => "@#{other_user.nickname}",
          "type" => "Mention"
        }

        expected_tag = %{
          "href" => Pleroma.Web.Endpoint.url() <> "/tags/2hu",
          "type" => "Hashtag",
          "name" => "#2hu"
        }

        refute called(Pleroma.Notification.get_notified_from_activity(:_, :_))
        assert Enum.member?(object["tag"], expected_tag)
        assert Enum.member?(object["tag"], expected_mention)
      end
    end

    test "it adds the sensitive property" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "#nsfw hey"})
      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["object"]["sensitive"]
    end

    test "it adds the json-ld context and the conversation property" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "hey"})
      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["@context"] == Utils.make_json_ld_header()["@context"]

      assert modified["object"]["conversation"] == modified["context"]
    end

    test "it sets the 'attributedTo' property to the actor of the object if it doesn't have one" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "hey"})
      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["object"]["actor"] == modified["object"]["attributedTo"]
    end

    test "it strips internal hashtag data" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "#2hu"})

      expected_tag = %{
        "href" => Pleroma.Web.Endpoint.url() <> "/tags/2hu",
        "type" => "Hashtag",
        "name" => "#2hu"
      }

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["object"]["tag"] == [expected_tag]
    end

    test "it strips internal fields" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "#2hu :firefox:"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert length(modified["object"]["tag"]) == 2

      assert is_nil(modified["object"]["emoji"])
      assert is_nil(modified["object"]["like_count"])
      assert is_nil(modified["object"]["announcements"])
      assert is_nil(modified["object"]["announcement_count"])
      assert is_nil(modified["object"]["context_id"])
    end

    test "it strips internal fields of article" do
      activity = insert(:article_activity)

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert length(modified["object"]["tag"]) == 2

      assert is_nil(modified["object"]["emoji"])
      assert is_nil(modified["object"]["like_count"])
      assert is_nil(modified["object"]["announcements"])
      assert is_nil(modified["object"]["announcement_count"])
      assert is_nil(modified["object"]["context_id"])
      assert is_nil(modified["object"]["likes"])
    end

    test "the directMessage flag is present" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "2hu :moominmamma:"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["directMessage"] == false

      {:ok, activity} = CommonAPI.post(user, %{status: "@#{other_user.nickname} :moominmamma:"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["directMessage"] == false

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "@#{other_user.nickname} :moominmamma:",
          visibility: "direct"
        })

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["directMessage"] == true
    end

    test "it strips BCC field" do
      user = insert(:user)
      {:ok, list} = Pleroma.List.create("foo", user)

      {:ok, activity} = CommonAPI.post(user, %{status: "foobar", visibility: "list:#{list.id}"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert is_nil(modified["bcc"])
    end
  end

  describe "user upgrade" do
    test "it upgrades a user to activitypub" do
      user =
        insert(:user, %{
          nickname: "rye@niu.moe",
          local: false,
          ap_id: "https://niu.moe/users/rye",
          follower_address: User.ap_followers(%User{nickname: "rye@niu.moe"})
        })

      user_two = insert(:user)
      Pleroma.FollowingRelationship.follow(user_two, user, :follow_accept)

      {:ok, activity} = CommonAPI.post(user, %{status: "test"})
      {:ok, unrelated_activity} = CommonAPI.post(user_two, %{status: "test"})
      assert "http://localhost:4001/users/rye@niu.moe/followers" in activity.recipients

      user = User.get_cached_by_id(user.id)
      assert user.note_count == 1

      {:ok, user} = Transmogrifier.upgrade_user_from_ap_id("https://niu.moe/users/rye")
      ObanHelpers.perform_all()

      assert user.ap_enabled
      assert user.note_count == 1
      assert user.follower_address == "https://niu.moe/users/rye/followers"
      assert user.following_address == "https://niu.moe/users/rye/following"

      user = User.get_cached_by_id(user.id)
      assert user.note_count == 1

      activity = Activity.get_by_id(activity.id)
      assert user.follower_address in activity.recipients

      assert %{
               "url" => [
                 %{
                   "href" =>
                     "https://cdn.niu.moe/accounts/avatars/000/033/323/original/fd7f8ae0b3ffedc9.jpeg"
                 }
               ]
             } = user.avatar

      assert %{
               "url" => [
                 %{
                   "href" =>
                     "https://cdn.niu.moe/accounts/headers/000/033/323/original/850b3448fa5fd477.png"
                 }
               ]
             } = user.banner

      refute "..." in activity.recipients

      unrelated_activity = Activity.get_by_id(unrelated_activity.id)
      refute user.follower_address in unrelated_activity.recipients

      user_two = User.get_cached_by_id(user_two.id)
      assert User.following?(user_two, user)
      refute "..." in User.following(user_two)
    end
  end

  describe "actor rewriting" do
    test "it fixes the actor URL property to be a proper URI" do
      data = %{
        "url" => %{"href" => "http://example.com"}
      }

      rewritten = Transmogrifier.maybe_fix_user_object(data)
      assert rewritten["url"] == "http://example.com"
    end
  end

  describe "actor origin containment" do
    test "it rejects activities which reference objects with bogus origins" do
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://mastodon.example.org/users/admin/activities/1234",
        "actor" => "http://mastodon.example.org/users/admin",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://info.pleroma.site/activity.json",
        "type" => "Announce"
      }

      assert capture_log(fn ->
               {:error, _} = Transmogrifier.handle_incoming(data)
             end) =~ "Object containment failed"
    end

    test "it rejects activities which reference objects that have an incorrect attribution (variant 1)" do
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://mastodon.example.org/users/admin/activities/1234",
        "actor" => "http://mastodon.example.org/users/admin",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://info.pleroma.site/activity2.json",
        "type" => "Announce"
      }

      assert capture_log(fn ->
               {:error, _} = Transmogrifier.handle_incoming(data)
             end) =~ "Object containment failed"
    end

    test "it rejects activities which reference objects that have an incorrect attribution (variant 2)" do
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://mastodon.example.org/users/admin/activities/1234",
        "actor" => "http://mastodon.example.org/users/admin",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://info.pleroma.site/activity3.json",
        "type" => "Announce"
      }

      assert capture_log(fn ->
               {:error, _} = Transmogrifier.handle_incoming(data)
             end) =~ "Object containment failed"
    end
  end

  describe "reserialization" do
    test "successfully reserializes a message with inReplyTo == nil" do
      user = insert(:user)

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "type" => "Create",
        "object" => %{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "id" => Utils.generate_object_id(),
          "type" => "Note",
          "content" => "Hi",
          "inReplyTo" => nil,
          "attributedTo" => user.ap_id
        },
        "actor" => user.ap_id
      }

      {:ok, activity} = Transmogrifier.handle_incoming(message)

      {:ok, _} = Transmogrifier.prepare_outgoing(activity.data)
    end

    test "successfully reserializes a message with AS2 objects in IR" do
      user = insert(:user)

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "type" => "Create",
        "object" => %{
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [],
          "id" => Utils.generate_object_id(),
          "type" => "Note",
          "content" => "Hi",
          "inReplyTo" => nil,
          "attributedTo" => user.ap_id,
          "tag" => [
            %{"name" => "#2hu", "href" => "http://example.com/2hu", "type" => "Hashtag"},
            %{"name" => "Bob", "href" => "http://example.com/bob", "type" => "Mention"}
          ]
        },
        "actor" => user.ap_id
      }

      {:ok, activity} = Transmogrifier.handle_incoming(message)

      {:ok, _} = Transmogrifier.prepare_outgoing(activity.data)
    end
  end

  describe "fix_explicit_addressing" do
    setup do
      user = insert(:user)
      [user: user]
    end

    test "moves non-explicitly mentioned actors to cc", %{user: user} do
      explicitly_mentioned_actors = [
        "https://pleroma.gold/users/user1",
        "https://pleroma.gold/user2"
      ]

      object = %{
        "actor" => user.ap_id,
        "to" => explicitly_mentioned_actors ++ ["https://social.beepboop.ga/users/dirb"],
        "cc" => [],
        "tag" =>
          Enum.map(explicitly_mentioned_actors, fn href ->
            %{"type" => "Mention", "href" => href}
          end)
      }

      fixed_object = Transmogrifier.fix_explicit_addressing(object, user.follower_address)
      assert Enum.all?(explicitly_mentioned_actors, &(&1 in fixed_object["to"]))
      refute "https://social.beepboop.ga/users/dirb" in fixed_object["to"]
      assert "https://social.beepboop.ga/users/dirb" in fixed_object["cc"]
    end

    test "does not move actor's follower collection to cc", %{user: user} do
      object = %{
        "actor" => user.ap_id,
        "to" => [user.follower_address],
        "cc" => []
      }

      fixed_object = Transmogrifier.fix_explicit_addressing(object, user.follower_address)
      assert user.follower_address in fixed_object["to"]
      refute user.follower_address in fixed_object["cc"]
    end

    test "removes recipient's follower collection from cc", %{user: user} do
      recipient = insert(:user)

      object = %{
        "actor" => user.ap_id,
        "to" => [recipient.ap_id, "https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [user.follower_address, recipient.follower_address]
      }

      fixed_object = Transmogrifier.fix_explicit_addressing(object, user.follower_address)

      assert user.follower_address in fixed_object["cc"]
      refute recipient.follower_address in fixed_object["cc"]
      refute recipient.follower_address in fixed_object["to"]
    end
  end

  describe "fix_summary/1" do
    test "returns fixed object" do
      assert Transmogrifier.fix_summary(%{"summary" => nil}) == %{"summary" => ""}
      assert Transmogrifier.fix_summary(%{"summary" => "ok"}) == %{"summary" => "ok"}
      assert Transmogrifier.fix_summary(%{}) == %{"summary" => ""}
    end
  end

  describe "fix_in_reply_to/2" do
    setup do: clear_config([:instance, :federation_incoming_replies_max_depth])

    setup do
      data = Poison.decode!(File.read!("test/fixtures/mastodon-post-activity.json"))
      [data: data]
    end

    test "returns not modified object when hasn't containts inReplyTo field", %{data: data} do
      assert Transmogrifier.fix_in_reply_to(data) == data
    end

    test "returns object with inReplyTo when denied incoming reply", %{data: data} do
      Pleroma.Config.put([:instance, :federation_incoming_replies_max_depth], 0)

      object_with_reply =
        Map.put(data["object"], "inReplyTo", "https://shitposter.club/notice/2827873")

      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == "https://shitposter.club/notice/2827873"

      object_with_reply =
        Map.put(data["object"], "inReplyTo", %{"id" => "https://shitposter.club/notice/2827873"})

      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == %{"id" => "https://shitposter.club/notice/2827873"}

      object_with_reply =
        Map.put(data["object"], "inReplyTo", ["https://shitposter.club/notice/2827873"])

      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == ["https://shitposter.club/notice/2827873"]

      object_with_reply = Map.put(data["object"], "inReplyTo", [])
      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)
      assert modified_object["inReplyTo"] == []
    end

    @tag capture_log: true
    test "returns modified object when allowed incoming reply", %{data: data} do
      object_with_reply =
        Map.put(
          data["object"],
          "inReplyTo",
          "https://mstdn.io/users/mayuutann/statuses/99568293732299394"
        )

      Pleroma.Config.put([:instance, :federation_incoming_replies_max_depth], 5)
      modified_object = Transmogrifier.fix_in_reply_to(object_with_reply)

      assert modified_object["inReplyTo"] ==
               "https://mstdn.io/users/mayuutann/statuses/99568293732299394"

      assert modified_object["context"] ==
               "tag:shitposter.club,2018-02-22:objectType=thread:nonce=e5a7c72d60a9c0e4"
    end
  end

  describe "fix_url/1" do
    test "fixes data for object when url is map" do
      object = %{
        "url" => %{
          "type" => "Link",
          "mimeType" => "video/mp4",
          "href" => "https://peede8d-46fb-ad81-2d4c2d1630e3-480.mp4"
        }
      }

      assert Transmogrifier.fix_url(object) == %{
               "url" => "https://peede8d-46fb-ad81-2d4c2d1630e3-480.mp4"
             }
    end

    test "returns non-modified object" do
      assert Transmogrifier.fix_url(%{"type" => "Text"}) == %{"type" => "Text"}
    end
  end

  describe "get_obj_helper/2" do
    test "returns nil when cannot normalize object" do
      assert capture_log(fn ->
               refute Transmogrifier.get_obj_helper("test-obj-id")
             end) =~ "Unsupported URI scheme"
    end

    @tag capture_log: true
    test "returns {:ok, %Object{}} for success case" do
      assert {:ok, %Object{}} =
               Transmogrifier.get_obj_helper(
                 "https://mstdn.io/users/mayuutann/statuses/99568293732299394"
               )
    end
  end

  describe "fix_attachments/1" do
    test "returns not modified object" do
      data = Poison.decode!(File.read!("test/fixtures/mastodon-post-activity.json"))
      assert Transmogrifier.fix_attachments(data) == data
    end

    test "returns modified object when attachment is map" do
      assert Transmogrifier.fix_attachments(%{
               "attachment" => %{
                 "mediaType" => "video/mp4",
                 "url" => "https://peertube.moe/stat-480.mp4"
               }
             }) == %{
               "attachment" => [
                 %{
                   "mediaType" => "video/mp4",
                   "type" => "Document",
                   "url" => [
                     %{
                       "href" => "https://peertube.moe/stat-480.mp4",
                       "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 }
               ]
             }
    end

    test "returns modified object when attachment is list" do
      assert Transmogrifier.fix_attachments(%{
               "attachment" => [
                 %{"mediaType" => "video/mp4", "url" => "https://pe.er/stat-480.mp4"},
                 %{"mimeType" => "video/mp4", "href" => "https://pe.er/stat-480.mp4"}
               ]
             }) == %{
               "attachment" => [
                 %{
                   "mediaType" => "video/mp4",
                   "type" => "Document",
                   "url" => [
                     %{
                       "href" => "https://pe.er/stat-480.mp4",
                       "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 },
                 %{
                   "mediaType" => "video/mp4",
                   "type" => "Document",
                   "url" => [
                     %{
                       "href" => "https://pe.er/stat-480.mp4",
                       "mediaType" => "video/mp4",
                       "type" => "Link"
                     }
                   ]
                 }
               ]
             }
    end
  end

  describe "fix_emoji/1" do
    test "returns not modified object when object not contains tags" do
      data = Poison.decode!(File.read!("test/fixtures/mastodon-post-activity.json"))
      assert Transmogrifier.fix_emoji(data) == data
    end

    test "returns object with emoji when object contains list tags" do
      assert Transmogrifier.fix_emoji(%{
               "tag" => [
                 %{"type" => "Emoji", "name" => ":bib:", "icon" => %{"url" => "/test"}},
                 %{"type" => "Hashtag"}
               ]
             }) == %{
               "emoji" => %{"bib" => "/test"},
               "tag" => [
                 %{"icon" => %{"url" => "/test"}, "name" => ":bib:", "type" => "Emoji"},
                 %{"type" => "Hashtag"}
               ]
             }
    end

    test "returns object with emoji when object contains map tag" do
      assert Transmogrifier.fix_emoji(%{
               "tag" => %{"type" => "Emoji", "name" => ":bib:", "icon" => %{"url" => "/test"}}
             }) == %{
               "emoji" => %{"bib" => "/test"},
               "tag" => %{"icon" => %{"url" => "/test"}, "name" => ":bib:", "type" => "Emoji"}
             }
    end
  end

  describe "set_replies/1" do
    setup do: clear_config([:activitypub, :note_replies_output_limit], 2)

    test "returns unmodified object if activity doesn't have self-replies" do
      data = Poison.decode!(File.read!("test/fixtures/mastodon-post-activity.json"))
      assert Transmogrifier.set_replies(data) == data
    end

    test "sets `replies` collection with a limited number of self-replies" do
      [user, another_user] = insert_list(2, :user)

      {:ok, %{id: id1} = activity} = CommonAPI.post(user, %{status: "1"})

      {:ok, %{id: id2} = self_reply1} =
        CommonAPI.post(user, %{status: "self-reply 1", in_reply_to_status_id: id1})

      {:ok, self_reply2} =
        CommonAPI.post(user, %{status: "self-reply 2", in_reply_to_status_id: id1})

      # Assuming to _not_ be present in `replies` due to :note_replies_output_limit is set to 2
      {:ok, _} = CommonAPI.post(user, %{status: "self-reply 3", in_reply_to_status_id: id1})

      {:ok, _} =
        CommonAPI.post(user, %{
          status: "self-reply to self-reply",
          in_reply_to_status_id: id2
        })

      {:ok, _} =
        CommonAPI.post(another_user, %{
          status: "another user's reply",
          in_reply_to_status_id: id1
        })

      object = Object.normalize(activity)
      replies_uris = Enum.map([self_reply1, self_reply2], fn a -> a.object.data["id"] end)

      assert %{"type" => "Collection", "items" => ^replies_uris} =
               Transmogrifier.set_replies(object.data)["replies"]
    end
  end

  test "take_emoji_tags/1" do
    user = insert(:user, %{emoji: %{"firefox" => "https://example.org/firefox.png"}})

    assert Transmogrifier.take_emoji_tags(user) == [
             %{
               "icon" => %{"type" => "Image", "url" => "https://example.org/firefox.png"},
               "id" => "https://example.org/firefox.png",
               "name" => ":firefox:",
               "type" => "Emoji",
               "updated" => "1970-01-01T00:00:00Z"
             }
           ]
  end
end
