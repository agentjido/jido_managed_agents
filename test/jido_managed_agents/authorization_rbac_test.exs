defmodule JidoManagedAgents.AuthorizationRBACTest do
  use ExUnit.Case, async: false

  alias AshAuthentication.Strategy.ApiKey.Plug, as: ApiKeyPlug
  alias JidoManagedAgents.AshActor
  alias JidoManagedAgentsWeb.LiveUserAuth

  defmodule Support.Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource JidoManagedAgents.AuthorizationRBACTest.Support.User
      resource JidoManagedAgents.AuthorizationRBACTest.Support.ApiKey
      resource JidoManagedAgents.AuthorizationRBACTest.Support.Document
    end
  end

  defmodule Support.User do
    require JidoManagedAgents.Authorization

    use Ash.Resource,
      otp_app: :jido_managed_agents,
      domain: JidoManagedAgents.AuthorizationRBACTest.Support.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshAuthentication]

    ets do
      private? true
    end

    authentication do
      strategies do
        api_key :api_key do
          api_key_relationship :valid_api_keys
        end
      end
    end

    actions do
      defaults [:read]

      create :create do
        accept [:email, :role]
      end

      update :update do
        accept [:email, :role]
      end

      read :sign_in_with_api_key do
        argument :api_key, :string, allow_nil?: false
        prepare AshAuthentication.Strategy.ApiKey.SignInPreparation
      end
    end

    policies do
      bypass AshAuthentication.Checks.AshAuthenticationInteraction do
        authorize_if always()
      end

      JidoManagedAgents.Authorization.platform_admin_override()

      policy action_type(:read) do
        authorize_if expr(id == ^actor(:id))
      end

      policy action_type(:update) do
        authorize_if expr(id == ^actor(:id))
      end
    end

    attributes do
      uuid_primary_key :id

      attribute :email, :string do
        allow_nil? false
        public? true
      end

      attribute :role, :atom do
        allow_nil? false
        default :member
        constraints one_of: [:member, :platform_admin]
        public? true
      end
    end

    relationships do
      has_many :valid_api_keys, JidoManagedAgents.AuthorizationRBACTest.Support.ApiKey do
        filter expr(expires_at > now())
      end
    end
  end

  defmodule Support.ApiKey do
    require JidoManagedAgents.Authorization

    use Ash.Resource,
      otp_app: :jido_managed_agents,
      domain: JidoManagedAgents.AuthorizationRBACTest.Support.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? true
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:user_id, :expires_at]

        change {AshAuthentication.Strategy.ApiKey.GenerateApiKey,
                prefix: :jidomanagedagents, hash: :api_key_hash}
      end
    end

    policies do
      bypass AshAuthentication.Checks.AshAuthenticationInteraction do
        authorize_if always()
      end

      JidoManagedAgents.Authorization.owner_or_admin_policies(:user)
    end

    attributes do
      attribute :id, :binary do
        allow_nil? false
        primary_key? true
        public? true
      end

      attribute :api_key_hash, :binary do
        allow_nil? false
        sensitive? true
      end

      attribute :expires_at, :utc_datetime_usec do
        allow_nil? false
      end
    end

    relationships do
      belongs_to :user, JidoManagedAgents.AuthorizationRBACTest.Support.User do
        allow_nil? false
      end
    end

    calculations do
      calculate :valid, :boolean, expr(expires_at > now())
    end

    identities do
      identity :unique_api_key, [:api_key_hash], pre_check_with: Support.Domain
    end
  end

  defmodule Support.Document do
    require JidoManagedAgents.Authorization

    use Ash.Resource,
      otp_app: :jido_managed_agents,
      domain: JidoManagedAgents.AuthorizationRBACTest.Support.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? true
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        accept [:name, :user_id]
      end

      update :update do
        accept [:name]
      end
    end

    policies do
      JidoManagedAgents.Authorization.owner_or_admin_policies(:user)
    end

    attributes do
      uuid_primary_key :id

      attribute :name, :string do
        allow_nil? false
        public? true
      end
    end

    relationships do
      belongs_to :user, JidoManagedAgents.AuthorizationRBACTest.Support.User do
        allow_nil? false
        public? true
      end
    end
  end

  setup_all do
    Application.put_env(:plug, :validate_header_keys_during_test, false, persistent: true)
    Code.ensure_loaded?(Comparable.Type.Any.To.Any)
    :ok
  end

  setup do
    on_exit(fn ->
      Ash.DataLayer.Ets.stop(Support.Document)
      Ash.DataLayer.Ets.stop(Support.ApiKey)
      Ash.DataLayer.Ets.stop(Support.User)
    end)

    :ok
  end

  test "production account resources standardize the role model and policy authorizer" do
    assert Ash.Resource.Info.authorizers(JidoManagedAgents.Accounts.User) == [
             Ash.Policy.Authorizer
           ]

    assert Ash.Resource.Info.authorizers(JidoManagedAgents.Accounts.ApiKey) == [
             Ash.Policy.Authorizer
           ]

    assert Ash.Resource.Info.authorizers(JidoManagedAgents.Accounts.Token) == [
             Ash.Policy.Authorizer
           ]

    role = Ash.Resource.Info.attribute(JidoManagedAgents.Accounts.User, :role)

    assert role.type == JidoManagedAgents.Accounts.UserRole
    assert role.default == :member

    assert JidoManagedAgents.Platform.Architecture.authorization_foundation().actor_roles == [
             :member,
             :platform_admin
           ]
  end

  test "owner-scoped policies allow owners and deny other members" do
    owner = create_user!()
    other = create_user!()

    assert {:ok, owner_doc} = create_document(owner, owner, "owner-doc")

    assert {:ok, other_doc} = create_document(other, other, "other-doc")

    assert {:ok, owner_doc} =
             owner_doc
             |> Ash.Changeset.for_update(:update, %{name: "owner-updated"},
               actor: owner,
               domain: Support.Domain
             )
             |> Ash.update()

    assert {:error, %Ash.Error.Forbidden{}} =
             owner_doc
             |> Ash.Changeset.for_destroy(:destroy, %{},
               actor: other,
               domain: Support.Domain
             )
             |> Ash.destroy()

    assert [owner_result] =
             Support.Document
             |> Ash.Query.for_read(:read, %{}, actor: owner, domain: Support.Domain)
             |> Ash.read!()

    assert owner_result.id == owner_doc.id
    assert owner_result.name == "owner-updated"

    assert [other_result] =
             Support.Document
             |> Ash.Query.for_read(:read, %{}, actor: other, domain: Support.Domain)
             |> Ash.read!()

    assert other_result.id == other_doc.id
  end

  test "platform admins bypass owner-scoped policies" do
    owner = create_user!()
    admin = create_user!(role: :platform_admin)

    assert {:ok, owner_doc} = create_document(owner, owner, "owner-doc")

    assert {:ok, %{name: "admin-updated"}} =
             owner_doc
             |> Ash.Changeset.for_update(:update, %{name: "admin-updated"},
               actor: admin,
               domain: Support.Domain
             )
             |> Ash.update()
  end

  test "api key auth resolves the owning user actor and inherits owner permissions" do
    owner = create_user!()
    other = create_user!()

    assert {:ok, owner_doc} = create_document(owner, owner, "owner-doc")
    assert {:ok, _other_doc} = create_document(other, other, "other-doc")

    api_key = create_api_key!(owner, owner)
    plaintext_api_key = api_key.__metadata__.plaintext_api_key

    conn =
      Plug.Test.conn("GET", "/documents")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext_api_key)
      |> ApiKeyPlug.call(ApiKeyPlug.init(resource: Support.User, required?: true))

    assert conn.assigns.current_user.id == owner.id
    assert Ash.PlugHelpers.get_actor(conn).id == owner.id

    assert [document] =
             Support.Document
             |> Ash.Query.for_read(:read, %{}, AshActor.ash_opts(conn, domain: Support.Domain))
             |> Ash.read!()

    assert document.id == owner_doc.id
  end

  test "browser auth resolves the session user as the Ash actor" do
    user = create_user!()
    assert {:ok, _document} = create_document(user, user, "browser-doc")

    conn =
      Plug.Test.conn("GET", "/")
      |> Plug.Conn.assign(:current_user, user)
      |> AshAuthentication.Plug.Helpers.set_actor(:user)

    assert Ash.PlugHelpers.get_actor(conn).id == user.id
    assert AshActor.actor(conn).id == user.id

    assert [document] =
             Support.Document
             |> Ash.Query.for_read(:read, %{}, AshActor.ash_opts(conn, domain: Support.Domain))
             |> Ash.read!()

    assert document.user_id == user.id
  end

  test "liveview and runtime helpers expose a consistent current_actor" do
    user = create_user!()

    socket = struct(Phoenix.LiveView.Socket, assigns: %{__changed__: %{}, current_user: user})

    assert {:cont, socket} = LiveUserAuth.on_mount(:live_user_optional, %{}, %{}, socket)
    assert socket.assigns.current_actor.id == user.id

    assert AshActor.actor(socket).id == user.id
    assert AshActor.jido_opts(socket, %{domain: Support.Domain}).actor.id == user.id

    blank_socket = struct(Phoenix.LiveView.Socket, assigns: %{__changed__: %{}})

    assert {:cont, blank_socket} =
             LiveUserAuth.on_mount(:live_no_user, %{}, %{}, blank_socket)

    assert blank_socket.assigns.current_actor == nil
  end

  defp create_user!(attrs \\ %{}) do
    attrs = Map.new(attrs)

    defaults = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      role: :member
    }

    Support.User
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs),
      domain: Support.Domain,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp create_document(actor, owner, name) do
    Support.Document
    |> Ash.Changeset.for_create(:create, %{name: name, user_id: owner.id},
      actor: actor,
      domain: Support.Domain
    )
    |> Ash.create()
  end

  defp create_api_key!(actor, owner) do
    Support.ApiKey
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      },
      actor: actor,
      domain: Support.Domain
    )
    |> Ash.create!()
  end
end
