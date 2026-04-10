defmodule JidoManagedAgents.SecretInfrastructureTest do
  use ExUnit.Case, async: false

  defmodule Support.Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource JidoManagedAgents.SecretInfrastructureTest.Support.EncryptedRecord
    end
  end

  defmodule Support.EncryptedRecord do
    use Ash.Resource,
      otp_app: :jido_managed_agents,
      domain: JidoManagedAgents.SecretInfrastructureTest.Support.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshCloak]

    ets do
      private? true
    end

    cloak do
      vault(JidoManagedAgents.Vault)
      attributes([:secret_value])
    end

    actions do
      defaults [:read]

      create :create do
        accept [:label, :secret_value]
      end
    end

    attributes do
      uuid_primary_key :id

      attribute :label, :string do
        allow_nil? false
        public? true
      end

      attribute :secret_value, :string do
        allow_nil? false
        public? true
      end
    end
  end

  setup_all do
    if is_nil(Process.whereis(JidoManagedAgents.Vault)) do
      start_supervised!(JidoManagedAgents.Vault)
    end

    :ok
  end

  setup do
    on_exit(fn ->
      Ash.DataLayer.Ets.stop(Support.EncryptedRecord)
    end)

    :ok
  end

  test "vault is configured for aes-gcm encryption with a test-safe key strategy" do
    plaintext = "vault-secret-#{System.unique_integer([:positive])}"

    ciphertext = JidoManagedAgents.Vault.encrypt!(plaintext)

    assert is_binary(ciphertext)
    refute ciphertext == plaintext
    assert JidoManagedAgents.Vault.decrypt!(ciphertext) == plaintext
    assert JidoManagedAgents.Vault.cipher_tag() == "AES.GCM.V1"
    assert JidoManagedAgents.Vault.iv_length() == 12
    assert JidoManagedAgents.Vault.key_source() in [:environment, :test_fallback]
  end

  test "runtime config exposes reusable secret encryption settings" do
    config = Application.fetch_env!(:jido_managed_agents, :secret_encryption)

    assert config[:env_var] == "JIDO_MANAGED_AGENTS_CLOAK_KEY"
    assert is_binary(config[:key])
    assert config[:source] in [:environment, :test_fallback]
  end

  test "AshCloak rewrites secret attributes to private encrypted storage" do
    assert Ash.Resource.Info.attribute(Support.EncryptedRecord, :secret_value) == nil

    assert %{public?: false, sensitive?: true} =
             Ash.Resource.Info.attribute(Support.EncryptedRecord, :encrypted_secret_value)

    assert %{public?: true, sensitive?: true} =
             Ash.Resource.Info.calculation(Support.EncryptedRecord, :secret_value)
  end

  test "encrypted values are persisted as ciphertext and omitted from default serialized payloads" do
    plaintext = "serialized-secret-#{System.unique_integer([:positive])}"

    record =
      Support.EncryptedRecord
      |> Ash.Changeset.for_create(:create, %{label: "api token", secret_value: plaintext},
        authorize?: false,
        domain: Support.Domain
      )
      |> Ash.create!()

    assert is_binary(record.encrypted_secret_value)
    refute record.encrypted_secret_value == plaintext
    assert %Ash.NotLoaded{type: :calculation, field: :secret_value} = record.secret_value

    serialized_payload = default_serialized_payload(record)
    json_payload = Jason.encode!(serialized_payload)

    refute Map.has_key?(serialized_payload, :secret_value)
    refute Map.has_key?(serialized_payload, :encrypted_secret_value)
    refute json_payload =~ plaintext

    loaded_record = Ash.load!(record, :secret_value, authorize?: false, domain: Support.Domain)

    assert loaded_record.secret_value == plaintext
  end

  defp default_serialized_payload(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(& &1.name)
    |> then(&Map.take(record, &1))
  end
end
