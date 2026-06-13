import { FormEvent, useEffect, useState } from "react";
import {
  type CanonicalModel,
  type CanonicalModelStatus,
  type Channel,
  createCanonicalModel,
  createModelAssociation,
  deleteCanonicalModel,
  deleteModelAssociation,
  listChannels,
  listCanonicalModels,
  listModelAssociations,
  listPriceVersions,
  type ModelAssociation,
  type ModelAssociationStatus,
  patchCanonicalModel,
  patchModelAssociation,
  type PriceVersion,
} from "../../api/client";
import { StateChip, errorMessage, fieldValue, formatStatus, jsonSize, parseJsonObject, shortId } from "../../components/adminUtils";
import { Edit3, FileInput, Plus, RefreshCw, RotateCcw, ShieldOff, Trash2, X } from "../../components/icons";
import { ModelAssociationDryRun } from "./ModelAssociationDryRun";
import { ModelPriceSummary } from "./ModelPriceSummary";

type ModelForm = {
  contextLength: string;
  defaultPriceBookId: string;
  displayName: string;
  family: string;
  modelKey: string;
  status: CanonicalModelStatus;
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
  defaultPriceBookId: "",
  displayName: "",
  family: "",
  modelKey: "",
  status: "active",
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
  const [channels, setChannels] = useState<Channel[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [modelForm, setModelForm] = useState<ModelForm>(defaultModelForm);
  const [models, setModels] = useState<CanonicalModel[]>([]);
  const [editingModel, setEditingModel] = useState<CanonicalModel | null>(null);
  const [openAssociationDialog, setOpenAssociationDialog] = useState(false);
  const [openModelDialog, setOpenModelDialog] = useState(false);
  const [priceVersions, setPriceVersions] = useState<PriceVersion[]>([]);
  const [priceBookSelections, setPriceBookSelections] = useState<Record<string, string>>({});
  const [success, setSuccess] = useState<string | null>(null);

  async function loadCatalog() {
    setError(null);
    setLoading(true);

    try {
      const [nextModels, nextAssociations, nextPriceVersions, nextChannels] = await Promise.all([
        listCanonicalModels(),
        listModelAssociations(),
        listPriceVersions({ status: "active", limit: 100 }),
        listChannels(),
      ]);
      setModels(nextModels);
      setAssociations(nextAssociations);
      setPriceVersions(nextPriceVersions);
      setChannels(nextChannels);
      setPriceBookSelections((current) => {
        const next = { ...current };

        for (const model of nextModels) {
          if (!(model.id in next)) {
            next[model.id] = model.default_price_book_id ?? "";
          }
        }

        return next;
      });
    } catch (requestError) {
      setError(errorMessage(requestError));
      setModels([]);
      setAssociations([]);
      setPriceVersions([]);
      setChannels([]);
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

  function openCreateModelDialog() {
    setEditingModel(null);
    setModelForm(defaultModelForm);
    setOpenModelDialog(true);
  }

  function openEditModelDialog(model: CanonicalModel) {
    setEditingModel(model);
    setModelForm({
      contextLength: model.context_length ? String(model.context_length) : "",
      defaultPriceBookId: model.default_price_book_id ?? "",
      displayName: model.display_name,
      family: model.family ?? "",
      modelKey: model.model_key,
      status: model.status,
      visibility: model.visibility,
    });
    setOpenModelDialog(true);
  }

  async function handleSubmitModel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const modelKey = modelForm.modelKey.trim();

    try {
      const request = {
        context_length: optionalPositiveInteger(modelForm.contextLength, "上下文长度"),
        default_price_book_id: optionalNullableString(modelForm.defaultPriceBookId),
        display_name: optionalString(modelForm.displayName),
        family: optionalString(modelForm.family),
        model_key: modelKey,
        status: modelForm.status,
        visibility: modelForm.visibility,
      };
      const saved = editingModel
        ? await patchCanonicalModel(editingModel.id, request)
        : await createCanonicalModel(request);
      setModelForm({ ...defaultModelForm, visibility: modelForm.visibility });
      setSuccess(editingModel ? `${saved.display_name} 已保存。` : "模型已创建。");
      setEditingModel(null);
      setOpenModelDialog(false);
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
      setSuccess(`${model.display_name} 已${modelStatusActionLabel(status)}。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function handleDefaultPriceBook(model: CanonicalModel, priceBookId: string) {
    setBusyId(model.id);
    setError(null);
    setSuccess(null);

    try {
      const updated = await patchCanonicalModel(model.id, {
        default_price_book_id: priceBookId.trim() ? priceBookId.trim() : null,
      });
      setModels((current) => current.map((item) => (item.id === updated.id ? updated : item)));
      setPriceBookSelections((current) => ({ ...current, [updated.id]: updated.default_price_book_id ?? "" }));
      setSuccess(`${model.display_name} 默认价格表已保存。`);
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
        conditions: parseJsonObject(associationForm.conditions, "条件"),
        fallback_allowed: associationForm.fallbackAllowed,
        model_pattern: optionalString(associationForm.modelPattern),
        priority: optionalNonNegativeInteger(associationForm.priority, "优先级"),
        upstream_model_name: optionalString(associationForm.upstreamModelName),
      });
      setAssociationForm({ ...defaultAssociationForm, canonicalModelId });
      setSuccess("模型关联已创建。");
      setOpenAssociationDialog(false);
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
      setSuccess(`关联 ${shortId(association.id)} 已${associationStatusActionLabel(status)}。`);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  function showImportPlaceholder(kind: "import" | "sync") {
    setError(null);
    setSuccess(
      kind === "import"
        ? "批量导入入口已预留：下一步接入 reviewed apply-plan，不在页面上传 provider key、认证头或上游 raw payload。"
        : "上游同步入口已预留：下一步只同步模型名称、渠道状态和映射摘要，不展示上游响应 payload 或凭据。",
    );
  }

  return (
    <div className="admin-page" aria-label="模型目录和关联">
      <section className="admin-panel" aria-label="模型目录控制区">
        <div className="section-heading">
          <div>
            <h2>模型目录</h2>
            <p>管理公开模型名称、渠道绑定和路由策略。</p>
          </div>
          <div className="action-row">
            <button className="primary-button primary-button--inline" type="button" onClick={openCreateModelDialog}>
              <Plus aria-hidden="true" size={17} />
              创建模型
            </button>
            <button className="secondary-button" type="button" onClick={() => setOpenAssociationDialog(true)}>
              <Plus aria-hidden="true" size={17} />
              创建关联
            </button>
            <button className="secondary-button" type="button" onClick={() => void loadCatalog()} disabled={loading}>
              <RefreshCw aria-hidden="true" size={18} className={loading ? "spin" : undefined} />
              刷新
            </button>
          </div>
        </div>

        <div className="status-grid status-grid--compact" aria-label="模型目录摘要">
          <article>
            <span>模型</span>
            <strong>{models.length}</strong>
            <p>{models.filter((model) => model.visibility === "public").length} 个公开</p>
          </article>
          <article>
            <span>关联</span>
            <strong>{associations.length}</strong>
            <p>{associations.filter((association) => association.status === "enabled").length} 个启用</p>
          </article>
          <article>
            <span>渠道</span>
            <strong>{channels.length}</strong>
            <p>可用路由目标</p>
          </article>
        </div>

        {error ? <p className="form-status form-status--error">{error}</p> : null}
        {success ? <p className="form-status form-status--success">{success}</p> : null}
      </section>

      <ModelTable
        busyId={busyId}
        onEdit={openEditModelDialog}
        loading={loading}
        models={models}
        onDefaultPriceBook={handleDefaultPriceBook}
        onPriceBookSelection={(modelId, priceBookId) =>
          setPriceBookSelections((current) => ({ ...current, [modelId]: priceBookId }))
        }
        onStatus={handleModelStatus}
        priceBookSelections={priceBookSelections}
        priceVersions={priceVersions}
      />

      <AssociationTable
        associations={associations}
        busyId={busyId}
        loading={loading}
        models={models}
        onStatus={handleAssociationStatus}
      />

      <MappingOperationsPanel onImport={() => showImportPlaceholder("import")} onSync={() => showImportPlaceholder("sync")} />

      <ModelAssociationDryRun models={models} priceVersions={priceVersions} />

      {openModelDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label={editingModel ? "编辑模型对话框" : "创建模型对话框"}>
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>模型目录</span>
                <h3>{editingModel ? "编辑模型" : "创建模型"}</h3>
                <p>维护用户通过 New API 兼容端点看到的 canonical model 名称、可见性、状态和默认价格。</p>
              </div>
              <button
                className="icon-button"
                type="button"
                onClick={() => {
                  setEditingModel(null);
                  setOpenModelDialog(false);
                }}
                aria-label="关闭模型对话框"
              >
                <X aria-hidden="true" size={18} />
              </button>
            </div>
            <form className="provider-form wizard-body" onSubmit={handleSubmitModel}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  模型 key
                  <input
                    value={modelForm.modelKey}
                    onChange={(event) => updateModel("modelKey", event.currentTarget.value)}
                    placeholder="gpt-4o-mini"
                    required
                  />
                </label>
                <label className="field">
                  显示名称
                  <input
                    value={modelForm.displayName}
                    onChange={(event) => updateModel("displayName", event.currentTarget.value)}
                    placeholder="GPT-4o Mini"
                  />
                </label>
                <label className="field">
                  系列
                  <input
                    value={modelForm.family}
                    onChange={(event) => updateModel("family", event.currentTarget.value)}
                    placeholder="gpt"
                  />
                </label>
                <label className="field">
                  可见性
                  <select value={modelForm.visibility} onChange={(event) => updateModel("visibility", event.currentTarget.value)}>
                    <option value="public">公开</option>
                    <option value="internal">内部</option>
                  </select>
                </label>
                <label className="field">
                  状态
                  <select value={modelForm.status} onChange={(event) => updateModel("status", event.currentTarget.value)}>
                    <option value="active">启用</option>
                    <option value="disabled">禁用</option>
                    <option value="deleted">已删除</option>
                  </select>
                </label>
                <label className="field">
                  默认价格表
                  <select
                    value={modelForm.defaultPriceBookId}
                    onChange={(event) => updateModel("defaultPriceBookId", event.currentTarget.value)}
                  >
                    <option value="">无默认</option>
                    {uniquePriceBookOptions(priceVersions).map((priceBookId) => (
                      <option key={priceBookId} value={priceBookId}>
                        {shortId(priceBookId)}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="field">
                  上下文长度
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
                {editingModel ? <Edit3 aria-hidden="true" size={17} /> : <Plus aria-hidden="true" size={17} />}
                {editingModel ? "保存模型" : "创建模型"}
              </button>
            </form>
          </div>
        </div>
      ) : null}

      {openAssociationDialog ? (
        <div className="wizard-overlay" role="dialog" aria-modal="true" aria-label="创建关联对话框">
          <div className="wizard-panel">
            <div className="wizard-header">
              <div>
                <span>路由</span>
                <h3>创建关联</h3>
                <p>将公开模型绑定到渠道、标签或模型模式，且不暴露上游凭据。</p>
              </div>
              <button
                className="icon-button"
                type="button"
                onClick={() => setOpenAssociationDialog(false)}
                aria-label="关闭创建关联对话框"
              >
                <X aria-hidden="true" size={18} />
              </button>
            </div>
            <form className="provider-form wizard-body" onSubmit={handleCreateAssociation}>
              <div className="form-grid form-grid--three">
                <label className="field">
                  关联模型 ID
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
                  关联类型
                  <select
                    value={associationForm.associationType}
                    onChange={(event) => updateAssociation("associationType", event.currentTarget.value)}
                  >
                    <option value="explicit_channel">指定渠道</option>
                    <option value="channel_tag">渠道标签</option>
                    <option value="model_pattern">模型模式</option>
                  </select>
                </label>
                <label className="field">
                  渠道 ID
                  <input
                    list="association-channel-id-options"
                    value={associationForm.channelId}
                    onChange={(event) => updateAssociation("channelId", event.currentTarget.value)}
                    placeholder="channel uuid"
                  />
                </label>
                <datalist id="association-channel-id-options">
                  {channels.map((channel) => (
                    <option key={channel.id} value={channel.id}>
                      {channel.name}
                    </option>
                  ))}
                </datalist>
                <label className="field">
                  渠道标签
                  <input
                    value={associationForm.channelTag}
                    onChange={(event) => updateAssociation("channelTag", event.currentTarget.value)}
                    placeholder="primary"
                  />
                </label>
                <label className="field">
                  模型模式
                  <input
                    value={associationForm.modelPattern}
                    onChange={(event) => updateAssociation("modelPattern", event.currentTarget.value)}
                    placeholder="openrouter/*"
                  />
                </label>
                <label className="field">
                  上游模型
                  <input
                    value={associationForm.upstreamModelName}
                    onChange={(event) => updateAssociation("upstreamModelName", event.currentTarget.value)}
                    placeholder="provider-model"
                  />
                </label>
                <label className="field">
                  优先级
                  <input
                    type="number"
                    value={associationForm.priority}
                    onChange={(event) => updateAssociation("priority", event.currentTarget.value)}
                  />
                </label>
                <label className="field">
                  条件 JSON
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
                  允许回退
                </label>
              </div>

              <button className="primary-button primary-button--inline" type="submit">
                <Plus aria-hidden="true" size={17} />
                创建关联
              </button>
            </form>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export default ModelsPage;

function ModelTable({
  busyId,
  loading,
  models,
  onDefaultPriceBook,
  onEdit,
  onPriceBookSelection,
  onStatus,
  priceBookSelections,
  priceVersions,
}: {
  busyId: string | null;
  loading: boolean;
  models: CanonicalModel[];
  onDefaultPriceBook: (model: CanonicalModel, priceBookId: string) => Promise<void>;
  onEdit: (model: CanonicalModel) => void;
  onPriceBookSelection: (modelId: string, priceBookId: string) => void;
  onStatus: (model: CanonicalModel, status: CanonicalModelStatus) => Promise<void>;
  priceBookSelections: Record<string, string>;
  priceVersions: PriceVersion[];
}) {
  const priceBookOptions = uniquePriceBookOptions(priceVersions);

  return (
    <section aria-label="模型列表">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--models">
          <thead>
            <tr>
              <th>模型</th>
              <th>状态</th>
              <th>可见性</th>
              <th>限制</th>
              <th>能力</th>
              <th>价格表</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={7}>正在加载模型。</td>
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
                    <span>最大输出 {fieldValue(model.max_output_tokens)}</span>
                  </td>
                  <td>
                    <span>工具 {yesNo(model.supports_tools)}</span>
                    <span>视觉 {yesNo(model.supports_vision)}</span>
                    <span>自定义 {jsonSize(model.capabilities)}</span>
                  </td>
                  <td>
                    <div className="action-row">
                      <select
                        aria-label={`${model.display_name} 的默认价格表`}
                        disabled={busyId === model.id}
                        onChange={(event) => onPriceBookSelection(model.id, event.currentTarget.value)}
                        value={priceBookSelections[model.id] ?? model.default_price_book_id ?? ""}
                      >
                        <option value="">无默认</option>
                        {priceBookOptions.map((priceBookId) => (
                          <option key={priceBookId} value={priceBookId}>
                            {shortId(priceBookId)}
                          </option>
                        ))}
                      </select>
                      <button
                        aria-label={`保存 ${model.display_name} 的默认价格表`}
                        className="table-action"
                        disabled={busyId === model.id}
                        onClick={() => void onDefaultPriceBook(model, priceBookSelections[model.id] ?? model.default_price_book_id ?? "")}
                        type="button"
                      >
                        保存
                      </button>
                    </div>
                    <ModelPriceSummary model={model} priceVersions={priceVersions} />
                  </td>
                  <td>
                    <div className="action-row">
                      <button
                        aria-label={`编辑模型 ${model.display_name}`}
                        className="table-action"
                        disabled={busyId === model.id}
                        onClick={() => onEdit(model)}
                        type="button"
                      >
                        <Edit3 aria-hidden="true" size={15} />
                        编辑
                      </button>
                      <button
                        aria-label={`启用模型 ${model.display_name}`}
                        className="table-action"
                        disabled={busyId === model.id || model.status === "active" || model.status === "deleted"}
                        onClick={() => void onStatus(model, "active")}
                        type="button"
                      >
                        <RotateCcw aria-hidden="true" size={15} />
                        启用
                      </button>
                      <button
                        aria-label={`停用模型 ${model.display_name}`}
                        className="table-action"
                        disabled={busyId === model.id || model.status === "disabled" || model.status === "deleted"}
                        onClick={() => void onStatus(model, "disabled")}
                        type="button"
                      >
                        <ShieldOff aria-hidden="true" size={15} />
                        停用
                      </button>
                      <button
                        aria-label={`删除模型 ${model.display_name}`}
                        className="table-action table-action--danger"
                        disabled={busyId === model.id || model.status === "deleted"}
                        onClick={() => void onStatus(model, "deleted")}
                        type="button"
                      >
                        <Trash2 aria-hidden="true" size={15} />
                        删除
                      </button>
                    </div>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={7}>暂无模型。</td>
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
    <section aria-label="模型关联列表">
      <div className="health-table-wrap">
        <table className="health-table admin-table admin-table--associations">
          <thead>
            <tr>
              <th>关联</th>
              <th>状态</th>
              <th>模型</th>
              <th>目标</th>
              <th>路由</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan={6}>正在加载模型关联。</td>
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
                    <strong>优先级 {association.priority}</strong>
                    <span>回退 {yesNo(association.fallback_allowed)}</span>
                    <span>金丝雀 {association.canary_percent}%</span>
                  </td>
                  <td>
                    <div className="action-row">
                      <button
                        aria-label={`停用关联 ${association.id}`}
                        className="table-action"
                        disabled={busyId === association.id || association.status === "disabled" || association.status === "deleted"}
                        onClick={() => void onStatus(association, "disabled")}
                        type="button"
                      >
                        <ShieldOff aria-hidden="true" size={15} />
                        停用
                      </button>
                      <button
                        aria-label={`启用关联 ${association.id}`}
                        className="table-action"
                        disabled={busyId === association.id || association.status === "enabled" || association.status === "deleted"}
                        onClick={() => void onStatus(association, "enabled")}
                        type="button"
                      >
                        <RotateCcw aria-hidden="true" size={15} />
                        启用
                      </button>
                      <button
                        aria-label={`删除关联 ${association.id}`}
                        className="table-action table-action--danger"
                        disabled={busyId === association.id || association.status === "deleted"}
                        onClick={() => void onStatus(association, "deleted")}
                        type="button"
                      >
                        <Trash2 aria-hidden="true" size={15} />
                        删除
                      </button>
                    </div>
                  </td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={6}>暂无模型关联。</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function MappingOperationsPanel({ onImport, onSync }: { onImport: () => void; onSync: () => void }) {
  return (
    <section className="admin-panel" aria-label="映射导入和同步入口">
      <div className="section-heading">
        <div>
          <h2>批量导入 / 同步</h2>
          <p>入口先预留为 reviewed apply-plan 和上游模型同步；当前页面只处理脱敏摘要，不接收 provider key 或 raw payload。</p>
        </div>
        <div className="action-row">
          <button className="secondary-button" type="button" onClick={onImport}>
            <FileInput aria-hidden="true" size={17} />
            导入映射
          </button>
          <button className="secondary-button" type="button" onClick={onSync}>
            <RefreshCw aria-hidden="true" size={17} />
            同步上游模型
          </button>
        </div>
      </div>
      <div className="status-grid status-grid--compact">
        <article>
          <span>导入计划</span>
          <strong>占位</strong>
          <p>后续接 Import Wizard apply-plan</p>
        </article>
        <article>
          <span>同步范围</span>
          <strong>模型摘要</strong>
          <p>provider / channel / upstream model name</p>
        </article>
        <article>
          <span>安全边界</span>
          <strong>Secret-safe</strong>
          <p>不展示认证头、provider key、upstream payload</p>
        </article>
      </div>
    </section>
  );
}

function modelName(modelId: string, models: CanonicalModel[]): string {
  return models.find((model) => model.id === modelId)?.model_key ?? "未知模型";
}

function uniquePriceBookOptions(priceVersions: PriceVersion[]): string[] {
  return [...new Set(priceVersions.map((version) => version.price_book_id).filter((priceBookId) => priceBookId.trim().length > 0))];
}

function optionalInteger(value: string, label: string): number | undefined {
  const trimmed = value.trim();

  if (!trimmed) {
    return undefined;
  }

  const parsed = Number(trimmed);

  if (!Number.isInteger(parsed)) {
    throw new Error(`${label}必须是整数。`);
  }

  return parsed;
}

function optionalPositiveInteger(value: string, label: string): number | undefined {
  const parsed = optionalInteger(value, label);

  if (parsed !== undefined && parsed <= 0) {
    throw new Error(`${label}必须大于 0。`);
  }

  return parsed;
}

function optionalNonNegativeInteger(value: string, label: string): number | undefined {
  const parsed = optionalInteger(value, label);

  if (parsed !== undefined && parsed < 0) {
    throw new Error(`${label}必须大于等于 0。`);
  }

  return parsed;
}

function optionalString(value: string): string | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : undefined;
}

function optionalNullableString(value: string): string | null | undefined {
  const trimmed = value.trim();

  return trimmed ? trimmed : null;
}

function modelStatusActionLabel(status: CanonicalModelStatus): string {
  if (status === "deleted") {
    return "删除";
  }

  if (status === "disabled") {
    return "停用";
  }

  if (status === "active") {
    return "启用";
  }

  return "更新";
}

function associationStatusActionLabel(status: ModelAssociationStatus): string {
  if (status === "deleted") {
    return "删除";
  }

  if (status === "disabled") {
    return "停用";
  }

  if (status === "enabled") {
    return "启用";
  }

  return "更新";
}

function yesNo(value: boolean): string {
  return value ? "是" : "否";
}
