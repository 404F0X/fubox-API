import { FormEvent, useEffect, useState } from "react";
import {
  type CanonicalModel,
  type CanonicalModelStatus,
  createCanonicalModel,
  createModelAssociation,
  deleteCanonicalModel,
  deleteModelAssociation,
  listCanonicalModels,
  listModelAssociations,
  type ModelAssociation,
  type ModelAssociationStatus,
  patchCanonicalModel,
  patchModelAssociation,
} from "../api/client";
import { StateChip, errorMessage, fieldValue, formatStatus, jsonSize, parseJsonObject, shortId } from "./adminUtils";
import { Plus, RefreshCw, ShieldOff, Trash2 } from "./icons";
import { ModelAssociationDryRun } from "./ModelAssociationDryRun";

type ModelForm = {
  contextLength: string;
  displayName: string;
  family: string;
  modelKey: string;
  visibility: string;
};

type AssociationForm = {
  associationType: string;
  canonicalModelId: string;
  channelId: string;
  channelTag: string;
  conditions: string;
  fallbackAllowed: boolean;
  modelPattern: string;
  priority: string;
  upstreamModelName: string;
};

const defaultModelForm: ModelForm = {
  contextLength: "",
  displayName: "",
  family: "",
  modelKey: "",
  visibility: "public",
};

const defaultAssociationForm: AssociationForm = {
  associationType: "explicit_channel",
  canonicalModelId: "",
  channelId: "",
  channelTag: "",
  conditions: "{}",
  fallbackAllowed: true,
  modelPattern: "",
  priority: "100",
  upstreamModelName: "",
};

export function ModelsPage() {
  const [associations, setAssociations] = useState<ModelAssociation[]>([]);
  const [associationForm, setAssociationForm] = useState<AssociationForm>(defaultAssociationForm);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [modelForm, setModelForm] = useState<ModelForm>(defaultModelForm);
  const [models, setModels] = useState<CanonicalModel[]>([]);
  const [success, setSuccess] = useState<string | null>(null);

  async function loadCatalog() {
    setError(null);
    setLoading(true);

    try {
      const [nextModels, nextAssociations] = await Promise.all([listCanonicalModels(), listModelAssociations()]);
      setModels(nextModels);
      setAssociations(nextAssociations);
    } catch (requestError) {
      setError(errorMessage(requestError));
      setModels([]);
      setAssociations([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadCatalog();
  }, []);

  function updateModel(field: keyof ModelForm, value: string) {
    setModelForm((current) => ({ ...current, [field]: value }));
  }

  function updateAssociation(field: keyof AssociationForm, value: string | boolean) {
    setAssociationForm((current) => ({ ...current, [field]: value }));
  }

  async function handleCreateModel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const modelKey = modelForm.modelKey.trim();

    try {
      await createCanonicalModel({
        context_length: optionalPositiveInteger(modelForm.contextLength, "Context length"),
        display_name: optionalString(modelForm.displayName),
        family: optionalString(modelForm.family),
        model_key: modelKey,
        visibility: modelForm.visibility,
      });
      setModelForm({ ...defaultModelForm, visibility: modelForm.visibility });
      setSuccess("Model created.");
      await loadCatalog();
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handleModelStatus(model: CanonicalModel, status: CanonicalModelStatus) {
    setBusyId(model.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = status === "deleted" ? await deleteCanonicalModel(model.id) : await patchCanonicalModel(model.id, { status });
      setModels((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`${model.display_name} ${status === "deleted" ? "deleted" : "disabled"}.`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleCreateAssociation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const canonicalModelId = associationForm.canonicalModelId.trim();

    try {
      await createModelAssociation({
        association_type: associationForm.associationType,
        canonical_model_id: canonicalModelId,
        channel_id: optionalString(associationForm.channelId),
        channel_tag: optionalString(associationForm.channelTag),
        conditions: parseJsonObject(associationForm.conditions, "Conditions"),
        fallback_allowed: associationForm.fallbackAllowed,
        model_pattern: optionalString(associationForm.modelPattern),
        priority: optionalNonNegativeInteger(associationForm.priority, "Priority"),
        upstream_model_name: optionalString(associationForm.upstreamModelName),
      });
      setAssociationForm({ ...defaultAssociationForm, canonicalModelId });
      setSuccess("Model association created.");
      await loadCatalog();
    } catch (requestError) {
      setError(errorMessage(requestError));
    }
  }

  async function handleAssociationStatus(association: ModelAssociation, status: ModelAssociationStatus) {
    setBusyId(association.id);
    setError(null);
    setSuccess(null);

    try {
      const updated =
        status === "deleted"
          ? await deleteModelAssociation(association.id)
          : await patchModelAssociation(association.id, { status });
      setAssociations((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setSuccess(`Association ${shortId(association.id)} ${status === "deleted" ? "deleted" : "disabled"}.`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="admin-page" aria-label="Model catalog and associations">
      <section className="admin-panel" aria-label="Model catalog controls">
        <div className="section-heading">
          <div>
            <h2>Model Catalog</h2>
          </div>
          <button className="secondary-button" type="button" onClick={() => void loadCatalog()} disabled={loading}>
            <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
            Refresh
          </button>
        </div>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <section className="admin-panel" aria-label="Create model">
        <div className="section-heading">
          <div>
            <h2>Create Model</h2>
          </div>
        </div>

        <form className="provider-form" onSubmit={handleCreateModel}>
          <div className="form-grid form-grid--three">
            <label className="field">
              Model key
              <input
                value={modelForm.modelKey}
                onChange={(event) => updateModel("modelKey", event.currentTarget.value)}
                placeholder="gpt-4o-mini"
                required
              />
            </label>
            <label className="field">
              Display name
              <input
                value={modelForm.displayName}
                onChange={(event) => updateModel("displayName", event.currentTarget.value)}
                placeholder="GPT-4o Mini"
              />
            </label>
            <label className="field">
              Family
              <input
                value={modelForm.family}
                onChange={(event) => updateModel("family", event.currentTarget.value)}
                placeholder="gpt"
              />
            </label>
            <label className="field">
              Visibility
              <select value={modelForm.visibility} onChange={(event) => updateModel("visibility", event.currentTarget.value)}>
                <option value="public">Public</option>
                <option value="internal">Internal</option>
              </select>
            </label>
            <label className="field">
              Context length
              <input
                min="1"
                type="number"
                value={modelForm.contextLength}
                onChange={(event) => updateModel("contextLength", event.currentTarget.value)}
                placeholder="128000"
              />
            </label>
          </div>

          <button className="primary-button primary-button--inline" type="submit">
            <Plus aria-hidden="true" size={17} />
            Create model
          </button>
        </form>
      </section>

      <ModelTable busyId={busyId} loading={loading} models={models} onStatus={handleModelStatus} />

      <section className="admin-panel" aria-label="Create model association">
        <div className="section-heading">
          <div>
            <h2>Create Association</h2>
          </div>
        </div>

        <form className="provider-form" onSubmit={handleCreateAssociation}>
          <div className="form-grid form-grid--three">
            <label className="field">
              Association model ID
              <input
                list="model-id-options"
                value={associationForm.canonicalModelId}
                onChange={(event) => updateAssociation("canonicalModelId", event.currentTarget.value)}
                placeholder="model uuid"
                required
              />
            </label>
            <datalist id="model-id-options">
              {models.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.model_key}
                </option>
              ))}
            </datalist>
            <label className="field">
              Association type
              <select
                value={associationForm.associationType}
                onChange={(event) => updateAssociation("associationType", event.currentTarget.value)}
              >
                <option value="explicit_channel">Explicit channel</option>
                <option value="channel_tag">Channel tag</option>
                <option value="model_pattern">Model pattern</option>
              </select>
            </label>
            <label className="field">
              Channel ID
              <input
                value={associationForm.channelId}
                onChange={(event) => updateAssociation("channelId", event.currentTarget.value)}
                placeholder="channel uuid"
              />
            </label>
            <label className="field">
              Channel tag
              <input
                value={associationForm.channelTag}
                onChange={(event) => updateAssociation("channelTag", event.currentTarget.value)}
                placeholder="primary"
              />
            </label>
            <label className="field">
              Model pattern
              <input
                value={associationForm.modelPattern}
                onChange={(event) => updateAssociation("modelPattern", event.currentTarget.value)}
                placeholder="openrouter/*"
              />
            </label>
            <label className="field">
              Upstream model
              <input
                value={associationForm.upstreamModelName}
                onChange={(event) => updateAssociation("upstreamModelName", event.currentTarget.value)}
                placeholder="provider-model"
              />
            </label>
            <label className="field">
              Priority
              <input
                type="number"
                value={associationForm.priority}
                onChange={(event) => updateAssociation("priority", event.currentTarget.value)}
              />
            </label>
            <label className="field">
              Conditions JSON
              <textarea
                value={associationForm.conditions}
                onChange={(event) => updateAssociation("conditions", event.currentTarget.value)}
                spellCheck={false}
              />
            </label>
            <label className="field field--checkbox">
              <input
                checked={associationForm.fallbackAllowed}
                onChange={(event) => updateAssociation("fallbackAllowed", event.currentTarget.checked)}
                type="checkbox"
              />
              Fallback allowed
            </label>
          </div>

          <button className="primary-button primary-button--inline" type="submit">
            <Plus aria-hidden="true" size={17} />
            Create association
          </button>
        </form>
      </section>

      <AssociationTable
        associations={associations}
        busyId={busyId}
        loading={loading}
        models={models}
        onStatus={handleAssociationStatus}
      />

      <ModelAssociationDryRun models={models} />
    </div>
  );
}

export default ModelsPage;

function ModelTable({
  busyId,
  loading,
  models,
  onStatus,
}: {
  busyId: string | null;
  loading: boolean;
  models: CanonicalModel[];
  onStatus: (model: CanonicalModel, status: CanonicalModelStatus) => Promise<void>;
}) {
  return (
    <section aria-label="Model list">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--models">
          <thead>
            <tr>
              <th>Model</th>
              <th>Status</th>
              <th>Visibility</th>
              <th>Limits</th>
              <th>Capabilities</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={6}>Loading models.</td>
              </tr>
            ) : models.length > 0 ? (
              models.map((model) => (
                <tr key={model.id}>
                  <td>
                    <strong>{model.display_name}</strong>
                    <span>
                      {model.model_key} / {shortId(model.id)}
                    </span>
                  </td>
                  <td>
                    <StateChip status={model.status} />
                  </td>
                  <td>
                    <strong>{formatStatus(model.visibility)}</strong>
                    <span>{fieldValue(model.family)}</span>
                  </td>
                  <td>
                    <strong>{fieldValue(model.context_length)}</strong>
                    <span>Max output {fieldValue(model.max_output_tokens)}</span>
                  </td>
                  <td>
                    <span>Tools {yesNo(model.supports_tools)}</span>
                    <span>Vision {yesNo(model.supports_vision)}</span>
                    <span>Custom {jsonSize(model.capabilities)}</span>
                  </td>
                  <td>
                    <div className="action-row">
                      <button
                        aria-label={`Disable model ${model.display_name}`}
                        className="table-action"
                        disabled={busyId === model.id || model.status === "disabled" || model.status === "deleted"}
                        onClick={() => void onStatus(model, "disabled")}
                        type="button"
                      >
                        <ShieldOff aria-hidden="true" size={15} />
                        Disable
                      </button>
                      <button
                        aria-label={`Delete model ${model.display_name}`}
                        className="table-action table-action--danger"
                        disabled={busyId === model.id || model.status === "deleted"}
                        onClick={() => void onStatus(model, "deleted")}
                        type="button"
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
                <td colSpan={6}>No models returned.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function AssociationTable({
  associations,
  busyId,
  loading,
  models,
  onStatus,
}: {
  associations: ModelAssociation[];
  busyId: string | null;
  loading: boolean;
  models: CanonicalModel[];
  onStatus: (association: ModelAssociation, status: ModelAssociationStatus) => Promise<void>;
}) {
  return (
    <section aria-label="Model association list">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--associations">
          <thead>
            <tr>
              <th>Association</th>
              <th>Status</th>
              <th>Model</th>
              <th>Target</th>
              <th>Routing</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={6}>Loading model associations.</td>
              </tr>
            ) : associations.length > 0 ? (
              associations.map((association) => (
                <tr key={association.id}>
                  <td>
                    <strong>{formatStatus(association.association_type)}</strong>
                    <span>{shortId(association.id)}</span>
                  </td>
                  <td>
                    <StateChip status={association.status} />
                  </td>
                  <td>
                    <strong>{modelName(association.canonical_model_id, models)}</strong>
                    <span>{shortId(association.canonical_model_id)}</span>
                  </td>
                  <td>
                    <strong>{fieldValue(association.channel_id ?? association.channel_tag ?? association.model_pattern)}</strong>
                    <span>{fieldValue(association.upstream_model_name)}</span>
                  </td>
                  <td>
                    <strong>Priority {association.priority}</strong>
                    <span>Fallback {yesNo(association.fallback_allowed)}</span>
                    <span>Canary {association.canary_percent}%</span>
                  </td>
                  <td>
                    <div className="action-row">
                      <button
                        aria-label={`Disable association ${association.id}`}
                        className="table-action"
                        disabled={busyId === association.id || association.status === "disabled" || association.status === "deleted"}
                        onClick={() => void onStatus(association, "disabled")}
                        type="button"
                      >
                        <ShieldOff aria-hidden="true" size={15} />
                        Disable
                      </button>
                      <button
                        aria-label={`Delete association ${association.id}`}
                        className="table-action table-action--danger"
                        disabled={busyId === association.id || association.status === "deleted"}
                        onClick={() => void onStatus(association, "deleted")}
                        type="button"
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
                <td colSpan={6}>No model associations returned.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function modelName(modelId: string, models: CanonicalModel[]): string {
  return models.find((model) => model.id === modelId)?.model_key ?? "Unknown model";
}

function optionalInteger(value: string, label: string): number | undefined {
  const trimmed = value.trim();

  if (!trimmed) {
    return undefined;
  }

  const parsed = Number(trimmed);

  if (!Number.isInteger(parsed)) {
    throw new Error(`${label} must be an integer.`);
  }

  return parsed;
}

function optionalPositiveInteger(value: string, label: string): number | undefined {
  const parsed = optionalInteger(value, label);

  if (parsed !== undefined && parsed <= 0) {
    throw new Error(`${label} must be greater than 0.`);
  }

  return parsed;
}

function optionalNonNegativeInteger(value: string, label: string): number | undefined {
  const parsed = optionalInteger(value, label);

  if (parsed !== undefined && parsed < 0) {
    throw new Error(`${label} must be 0 or greater.`);
  }

  return parsed;
}

function optionalString(value: string): string | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : undefined;
}

function yesNo(value: boolean): string {
  return value ? "Yes" : "No";
}
