import { FormEvent, useEffect, useState } from "react";
import {
  type Channel,
  type ChannelManualTestRequest,
  type ChannelManualTestResponse,
  type ChannelStatus,
  createChannel,
  createProvider,
  deleteChannel,
  deleteProvider,
  dryRunChannelManualTest,
  type JsonValue,
  listChannels,
  listProviders,
  patchChannel,
  patchProvider,
  type Provider,
  type ProviderStatus,
} from "../api/client";
import { StateChip, errorMessage, fieldValue, formatStatus, isJsonRecord, safeFieldValue, shortId } from "./adminUtils";
import { Plus, RefreshCw, Search, ShieldOff, Trash2 } from "./icons";

type ProviderForm = {
  baseUrl: string;
  code: string;
  name: string;
  providerType: string;
};

type ChannelForm = {
  endpoint: string;
  name: string;
  providerId: string;
};

type ChannelManualTestForm = {
  requestedModel: string;
  upstreamModel: string;
};

const defaultProviderForm: ProviderForm = {
  baseUrl: "",
  code: "",
  name: "",
  providerType: "",
};
const defaultChannelForm: ChannelForm = {
  endpoint: "",
  name: "",
  providerId: "",
};
const defaultChannelManualTestForm: ChannelManualTestForm = {
  requestedModel: "",
  upstreamModel: "",
};

type ProvidersPageProps = {
  canManageProviders: boolean;
  canRunManualTest: boolean;
};

export function ProvidersPage({ canManageProviders, canRunManualTest }: ProvidersPageProps) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [channelForm, setChannelForm] = useState<ChannelForm>(defaultChannelForm);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [manualBusyId, setManualBusyId] = useState<string | null>(null);
  const [manualError, setManualError] = useState<string | null>(null);
  const [manualForms, setManualForms] = useState<Record<string, ChannelManualTestForm>>({});
  const [manualResult, setManualResult] = useState<{
    channelId: string;
    result: ChannelManualTestResponse;
  } | null>(null);
  const [providerForm, setProviderForm] = useState<ProviderForm>(defaultProviderForm);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [success, setSuccess] = useState<string | null>(null);

  async function loadInventory() {
    setError(null);
    setLoading(true);

    try {
      const [nextProviders, nextChannels] = await Promise.all([listProviders(), listChannels()]);
      setProviders(nextProviders);
      setChannels(nextChannels);
    } catch (requestError) {
      setError(errorMessage(requestError));
      setProviders([]);
      setChannels([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadInventory();
  }, []);

  function updateProvider(field: keyof ProviderForm, value: string) {
    setProviderForm((current) => ({ ...current, [field]: value }));
  }

  function updateChannel(field: keyof ChannelForm, value: string) {
    setChannelForm((current) => ({ ...current, [field]: value }));
  }

  function updateManualTestForm(channelId: string, field: keyof ChannelManualTestForm, value: string) {
    setManualForms((current) => ({
      ...current,
      [channelId]: {
        ...(current[channelId] ?? defaultChannelManualTestForm),
        [field]: value,
      },
    }));
  }

  async function handleCreateProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    try {
      await createProvider({
        base_url: optionalString(providerForm.baseUrl),
        code: providerForm.code.trim(),
        name: providerForm.name.trim(),
        provider_type: optionalString(providerForm.providerType),
      });
      setProviderForm(defaultProviderForm);
      setSuccess("Provider created.");
      await loadInventory();
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handleProviderStatus(provider: Provider, status: ProviderStatus) {
    setBusyId(provider.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = status === "deleted" ? await deleteProvider(provider.id) : await patchProvider(provider.id, { status });
      setProviders((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${provider.name} ${status === "deleted" ? "deleted" : "disabled"}.`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleCreateChannel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const providerId = channelForm.providerId.trim();

    try {
      await createChannel({
        endpoint: channelForm.endpoint.trim(),
        name: channelForm.name.trim(),
        provider_id: providerId,
      });
      setChannelForm({ ...defaultChannelForm, providerId });
      setSuccess("Channel created.");
      await loadInventory();
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handleChannelStatus(channel: Channel, status: ChannelStatus) {
    setBusyId(channel.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = status === "deleted" ? await deleteChannel(channel.id) : await patchChannel(channel.id, { status });
      setChannels((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${channel.name} ${status === "deleted" ? "deleted" : "disabled"}.`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleChannelManualTest(channel: Channel, event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setManualBusyId(channel.id);
    setManualError(null);
    setSuccess(null);

    const form = manualForms[channel.id] ?? defaultChannelManualTestForm;
    const requestedModel = form.requestedModel.trim();
    const upstreamModel = form.upstreamModel.trim();

    if (!requestedModel) {
      setManualError("Requested model is required.");
      setManualBusyId(null);
      return;
    }

    const request: ChannelManualTestRequest = {
      dry_run: true,
      model: requestedModel,
      upstream_model_name: upstreamModel || undefined,
    };

    try {
      const result = await dryRunChannelManualTest(channel.id, request);
      setManualResult({ channelId: channel.id, result });
      setSuccess(`${channel.name} manual test dry-run ready.`);
    } catch (requestError) {
      setManualError(errorMessage(requestError));
      setManualResult(null);
    } finally {
      setManualBusyId(null);
    }
  }

  return (
    <div className="admin-page" aria-label="Providers and channels">
      <section className="admin-panel" aria-label="Provider inventory controls">
        <div className="section-heading">
          <div>
            <h2>Provider Inventory</h2>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadInventory()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {manualError ? <p className="form-status form-status--error">{manualError}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      {canManageProviders ? (
          <section className="admin-panel" aria-label="Create provider">
            <div className="section-heading">
              <div>
                <h2>Create Provider</h2>
              </div>
            </div>

            <form className="provider-form" onSubmit={handleCreateProvider}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  Provider code
                  <input
                    value={providerForm.code}
                    onChange={(event) => updateProvider("code", event.currentTarget.value)}
                    placeholder="openai"
                    required
                  />
                </label>
                <label className="field">
                  Provider name
                  <input
                    value={providerForm.name}
                    onChange={(event) => updateProvider("name", event.currentTarget.value)}
                    placeholder="OpenAI"
                    required
                  />
                </label>
                <label className="field">
                  Provider type
                  <input
                    value={providerForm.providerType}
                    onChange={(event) => updateProvider("providerType", event.currentTarget.value)}
                    placeholder="openai"
                  />
                </label>
                <label className="field">
                  Provider base URL
                  <input
                    value={providerForm.baseUrl}
                    onChange={(event) => updateProvider("baseUrl", event.currentTarget.value)}
                    placeholder="https://api.openai.com/v1"
                    type="url"
                  />
                </label>
              </div>

              <button className="primary-button primary-button--inline" type="submit">
                <Plus aria-hidden="true" size={17} />
                Create provider
              </button>
            </form>
          </section>
      ) : null}

      <ProviderTable
        busyId={busyId}
        canManageProviders={canManageProviders}
        channels={channels}
        loading={loading}
        providers={providers}
        onStatus={handleProviderStatus}
      />

      {canManageProviders ? (
          <section className="admin-panel" aria-label="Create channel">
            <div className="section-heading">
              <div>
                <h2>Create Channel</h2>
              </div>
            </div>

            <form className="provider-form" onSubmit={handleCreateChannel}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  Channel provider ID
                  <input
                    list="provider-id-options"
                    value={channelForm.providerId}
                    onChange={(event) => updateChannel("providerId", event.currentTarget.value)}
                    placeholder="provider uuid"
                    required
                  />
                </label>
                <datalist id="provider-id-options">
                  {providers.map((provider) => (
                    <option key={provider.id} value={provider.id}>
                      {provider.name}
                    </option>
                  ))}
                </datalist>
                <label className="field">
                  Channel name
                  <input
                    value={channelForm.name}
                    onChange={(event) => updateChannel("name", event.currentTarget.value)}
                    placeholder="primary us-east"
                    required
                  />
                </label>
                <label className="field">
                  Endpoint / base URL
                  <input
                    value={channelForm.endpoint}
                    onChange={(event) => updateChannel("endpoint", event.currentTarget.value)}
                    placeholder="https://api.openai.com/v1"
                    required
                    type="url"
                  />
                </label>
              </div>

              <button className="primary-button primary-button--inline" type="submit">
                <Plus aria-hidden="true" size={17} />
                Create channel
              </button>
            </form>
          </section>
      ) : null}

      <ChannelTable
        busyId={busyId}
        canManageProviders={canManageProviders}
        canRunManualTest={canRunManualTest}
        channels={channels}
        loading={loading}
        manualBusyId={manualBusyId}
        manualForms={manualForms}
        providers={providers}
        onManualFormChange={updateManualTestForm}
        onManualTest={handleChannelManualTest}
        onStatus={handleChannelStatus}
      />
      {manualResult ? <ChannelManualTestResult result={manualResult.result} /> : null}
    </div>
  );
}

function ProviderTable({
  busyId,
  canManageProviders,
  channels,
  loading,
  providers,
  onStatus,
}: {
  busyId: string | null;
  canManageProviders: boolean;
  channels: Channel[];
  loading: boolean;
  providers: Provider[];
  onStatus: (provider: Provider, status: ProviderStatus) => Promise<void>;
}) {
  return (
    <section aria-label="Provider list">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--providers">
          <thead>
            <tr>
              <th>Provider</th>
              <th>Status</th>
              <th>Type / Base URL</th>
              <th>Channels</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={5}>Loading providers.</td>
              </tr>
            ) : providers.length > 0 ? (
              providers.map((provider) => (
                <tr key={provider.id}>
                  <td>
                    <strong>{provider.name}</strong>
                    <span>
                      {provider.code} / {shortId(provider.id)}
                    </span>
                  </td>
                  <td>
                    <StateChip status={provider.status} />
                  </td>
                  <td>
                    <strong>{fieldValue(providerMetadata(provider, "provider_type"))}</strong>
                    <span>{fieldValue(providerMetadata(provider, "base_url"))}</span>
                  </td>
                  <td>
                    <strong>{channels.filter((channel) => channel.provider_id === provider.id).length}</strong>
                    <span>attached channels</span>
                  </td>
                  <td>
                    <div className="action-row">
                      <button
                        className="table-action"
                        type="button"
                        onClick={() => void onStatus(provider, "disabled")}
                        disabled={
                          !canManageProviders ||
                          busyId === provider.id ||
                          provider.status === "disabled" ||
                          provider.status === "deleted"
                        }
                        aria-label={`Disable provider ${provider.name}`}
                      >
                        <ShieldOff aria-hidden="true" size={15} />
                        Disable
                      </button>
                      <button
                        className="table-action table-action--danger"
                        type="button"
                        onClick={() => void onStatus(provider, "deleted")}
                        disabled={!canManageProviders || busyId === provider.id || provider.status === "deleted"}
                        aria-label={`Delete provider ${provider.name}`}
                      >
                        <Trash2 aria-hidden="true" size={15} />
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={5}>No providers returned.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ChannelTable({
  busyId,
  canManageProviders,
  canRunManualTest,
  channels,
  loading,
  manualBusyId,
  manualForms,
  providers,
  onManualFormChange,
  onManualTest,
  onStatus,
}: {
  busyId: string | null;
  canManageProviders: boolean;
  canRunManualTest: boolean;
  channels: Channel[];
  loading: boolean;
  manualBusyId: string | null;
  manualForms: Record<string, ChannelManualTestForm>;
  providers: Provider[];
  onManualFormChange: (channelId: string, field: keyof ChannelManualTestForm, value: string) => void;
  onManualTest: (channel: Channel, event: FormEvent<HTMLFormElement>) => Promise<void>;
  onStatus: (channel: Channel, status: ChannelStatus) => Promise<void>;
}) {
  return (
    <section aria-label="Channel list">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--channels">
          <thead>
            <tr>
              <th>Channel</th>
              <th>Status</th>
              <th>Provider</th>
              <th>Endpoint</th>
              <th>Manual Test</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={6}>Loading channels.</td>
              </tr>
            ) : channels.length > 0 ? (
              channels.map((channel) => {
                const manualForm = manualForms[channel.id] ?? defaultChannelManualTestForm;
                const modelOptions = modelMappingOptions(channel);
                const requestedListId = `manual-test-requested-${channel.id}`;
                const upstreamListId = `manual-test-upstream-${channel.id}`;

                return (
                  <tr key={channel.id}>
                    <td>
                      <strong>{channel.name}</strong>
                      <span>{shortId(channel.id)}</span>
                    </td>
                    <td>
                      <StateChip status={channel.status} />
                      <span>{formatStatus(channel.protocol_mode)}</span>
                    </td>
                    <td>
                      <strong>{providerName(channel.provider_id, providers)}</strong>
                      <span>{shortId(channel.provider_id)}</span>
                    </td>
                    <td>
                      <strong>{fieldValue(channel.region)}</strong>
                      <span>{channel.endpoint}</span>
                    </td>
                    <td>
                      {canRunManualTest ? (
                        <form className="manual-test-form" onSubmit={(event) => void onManualTest(channel, event)}>
                          <label className="manual-test-field">
                            Requested model
                            <input
                              list={requestedListId}
                              onChange={(event) =>
                                onManualFormChange(channel.id, "requestedModel", event.currentTarget.value)
                              }
                              required
                              value={manualForm.requestedModel}
                            />
                          </label>
                          <datalist id={requestedListId}>
                            {modelOptions.requested.map((model) => (
                              <option key={model} value={model} />
                            ))}
                          </datalist>
                          <label className="manual-test-field">
                            Upstream model
                            <input
                              list={upstreamListId}
                              onChange={(event) =>
                                onManualFormChange(channel.id, "upstreamModel", event.currentTarget.value)
                              }
                              value={manualForm.upstreamModel}
                            />
                          </label>
                          <datalist id={upstreamListId}>
                            {modelOptions.upstream.map((model) => (
                              <option key={model} value={model} />
                            ))}
                          </datalist>
                          <button
                            className="table-action"
                            type="submit"
                            disabled={manualBusyId === channel.id || channel.status === "deleted"}
                            aria-label={`Run manual test for ${channel.name}`}
                          >
                            <Search aria-hidden="true" size={15} />
                            {manualBusyId === channel.id ? "Running" : "Test"}
                          </button>
                        </form>
                      ) : (
                        <span className="muted-copy">Unavailable</span>
                      )}
                    </td>
                    <td>
                      <div className="action-row">
                        <button
                          className="table-action"
                          type="button"
                          onClick={() => void onStatus(channel, "disabled")}
                          disabled={
                            !canManageProviders ||
                            busyId === channel.id ||
                            channel.status === "disabled" ||
                            channel.status === "deleted"
                          }
                          aria-label={`Disable channel ${channel.name}`}
                        >
                          <ShieldOff aria-hidden="true" size={15} />
                          Disable
                        </button>
                        <button
                          className="table-action table-action--danger"
                          type="button"
                          onClick={() => void onStatus(channel, "deleted")}
                          disabled={!canManageProviders || busyId === channel.id || channel.status === "deleted"}
                          aria-label={`Delete channel ${channel.name}`}
                        >
                          <Trash2 aria-hidden="true" size={15} />
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })
            ) : (
              <tr>
                <td colSpan={6}>No channels returned.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ChannelManualTestResult({ result }: { result: ChannelManualTestResponse }) {
  return (
    <section className="detail-grid" aria-label="Channel manual test result">
      <article className="admin-panel">
        <div className="section-heading">
          <div>
            <h2>Channel Manual Test</h2>
            <p>{safeFieldValue(result.test_mode)}</p>
          </div>
          <StateChip status={result.dry_run ? "dry_run" : "live"} />
        </div>
        <div className="manual-test-flags" aria-label="Manual test safety flags">
          <span>upstream_call={String(result.upstream_call)}</span>
          <span>billable={String(result.billing.billable)}</span>
          <span>ledger_write={String(result.billing.ledger_write)}</span>
        </div>
        <DetailFields
          items={[
            ["Requested model", result.requested_model],
            ["Upstream model", result.upstream_model],
            ["Request log write", String(result.billing.request_log_write)],
            ["Credential material", "omitted"],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Channel</h2>
        <DetailFields
          items={[
            ["Name", result.channel.name],
            ["ID", safeShortId(result.channel.id)],
            ["Status", result.channel.status],
            ["Protocol", result.channel.protocol_mode],
            ["Endpoint", result.channel.endpoint],
            ["Priority / weight", `${result.channel.priority} / ${result.channel.weight}`],
            ["Health score", result.channel.health_score],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Provider</h2>
        <DetailFields
          items={[
            ["Name", result.provider.name],
            ["Code", result.provider.code],
            ["ID", safeShortId(result.provider.id)],
            ["Status", result.provider.status],
          ]}
        />
      </article>

      <article className="admin-panel">
        <h2>Request Plan</h2>
        <DetailFields
          items={[
            ["Method", result.request_plan.method],
            ["Path", result.request_plan.path],
            ["Protocol", result.request_plan.protocol_mode],
            ["Model", result.request_plan.model],
          ]}
        />
      </article>
    </section>
  );
}

function DetailFields({ items }: { items: Array<[string, unknown]> }) {
  return (
    <dl className="detail-list">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{safeFieldValue(value)}</dd>
        </div>
      ))}
    </dl>
  );
}

function optionalString(value: string): string | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : undefined;
}

function providerMetadata(provider: Provider, key: "base_url" | "provider_type"): string | undefined {
  const direct = key === "provider_type" ? provider.provider_type : provider.base_url;

  if (direct) {
    return direct;
  }

  if (typeof provider.metadata !== "object" || provider.metadata === null || Array.isArray(provider.metadata)) {
    return undefined;
  }

  const value = provider.metadata[key];

  return typeof value === "string" && value.trim() ? value : undefined;
}

function providerName(providerId: string, providers: Provider[]): string {
  return providers.find((provider) => provider.id === providerId)?.name ?? "Unknown provider";
}

function modelMappingOptions(channel: Channel): { requested: string[]; upstream: string[] } {
  const requested = new Set<string>();
  const upstream = new Set<string>();

  collectMappingOptions(channel.model_mappings, requested, upstream);

  return {
    requested: [...requested].sort(),
    upstream: [...upstream].sort(),
  };
}

function collectMappingOptions(value: JsonValue, requested: Set<string>, upstream: Set<string>) {
  if (Array.isArray(value)) {
    for (const item of value) {
      collectMappingPair(item, requested, upstream);
    }
    return;
  }

  if (!isJsonRecord(value)) {
    return;
  }

  for (const [key, child] of Object.entries(value)) {
    if (typeof child === "string" && !isModelMappingPolicyKey(key)) {
      addOption(requested, key);
      addOption(upstream, child);
    } else if (key === "explicit_mappings" || key === "mappings") {
      collectMappingOptions(child, requested, upstream);
    }
  }
}

function collectMappingPair(value: JsonValue, requested: Set<string>, upstream: Set<string>) {
  if (!isJsonRecord(value)) {
    return;
  }

  const requestedModel = stringField(value, "requested_model") ?? stringField(value, "model");
  const upstreamModel = stringField(value, "upstream_model") ?? stringField(value, "upstream_model_name");

  addOption(requested, requestedModel);
  addOption(upstream, upstreamModel);
}

function stringField(value: Record<string, JsonValue>, key: string): string | undefined {
  const field = value[key];

  return typeof field === "string" ? field : undefined;
}

function addOption(options: Set<string>, value: string | undefined) {
  const trimmed = value?.trim();

  if (trimmed) {
    options.add(trimmed);
  }
}

function isModelMappingPolicyKey(key: string): boolean {
  return ["case_policy", "explicit_mappings", "mappings", "trim_prefixes"].includes(key);
}

function safeShortId(value: string | null | undefined): string {
  if (!value) {
    return "-";
  }

  const safeValue = safeFieldValue(value);

  return safeValue === value ? shortId(value) : safeValue;
}
