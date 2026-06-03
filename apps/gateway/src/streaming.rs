use std::{
    fmt, io,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};

use ai_gateway_adapters::{ChatCompletionRequest, OpenAiChatStream};
use ai_gateway_billing_ledger::{TokenUsage, rate_usage_from_json};
use ai_gateway_stream::{
    SseDecodeError, SseDecoder, SseEvent, StreamEndReason, StreamEndSignal, StreamProtocol,
    TerminalEventKind, stream_end_reason_for_terminal_kind, terminal_event_kind,
};
use axum::{
    body::{Body, Bytes},
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{CACHE_CONTROL, CONTENT_TYPE},
    },
    response::{IntoResponse, Response},
};
use futures::stream;
use serde_json::{Value, json};

use crate::{
    EndpointRequestFinalMetrics, OpenAiClientCache, cached_openai_client,
    db::{
        AuthContext, GatewayRepository, LedgerSettleEntry, ResolvedChatRoute, ResolvedPriceVersion,
        StreamProviderAttemptFinalUpdate, StreamRequestFinalUpdate,
    },
    elapsed_ms,
    errors::{adapter_error_response, summarize_adapter_error},
    fallback_event, finish_provider_attempt_with_adapter_error,
    finish_provider_attempt_with_adapter_error_and_fallback, finish_provider_attempt_with_error,
    finish_request_with_error, open_provider_key_for_route, pre_authorize_before_provider_attempt,
    provider_attempt_fallback_metadata, provider_error_can_fallback,
    record_endpoint_request_final_metrics, record_request_final_route, request_for_upstream,
    route_snapshot_with_final_attempt,
};

const OPENAI_STREAM_MAX_EVENT_BYTES: usize = 4 * 1024 * 1024;
const OPENAI_STREAM_MAX_CHUNK_BYTES: usize = OPENAI_STREAM_MAX_EVENT_BYTES;

pub(crate) struct StreamingChatContext<'a> {
    pub(crate) repository: &'a GatewayRepository,
    pub(crate) auth: &'a AuthContext,
    pub(crate) request_id: uuid::Uuid,
    pub(crate) request_started_at: Instant,
    pub(crate) request: &'a ChatCompletionRequest,
    pub(crate) attempt_routes: &'a [ResolvedChatRoute],
    pub(crate) upstream_clients: &'a mut OpenAiClientCache,
    pub(crate) route_snapshot: Value,
}

pub(crate) async fn chat_completions_streaming(context: StreamingChatContext<'_>) -> Response {
    let StreamingChatContext {
        repository,
        auth,
        request_id,
        request_started_at,
        request,
        attempt_routes,
        upstream_clients,
        route_snapshot,
    } = context;

    debug_assert!(request.is_streaming());

    let mut fallback_events = Vec::new();

    for (attempt_index, route) in attempt_routes.iter().enumerate() {
        let attempt_no = i32::try_from(attempt_index + 1).unwrap_or(i32::MAX);
        if let Some(response) = pre_authorize_before_provider_attempt(
            crate::METRICS_ENDPOINT_CHAT_COMPLETIONS,
            repository,
            auth,
            request_id,
            request_started_at,
            route,
        )
        .await
        {
            return response;
        }

        let attempt_id = match repository
            .create_provider_attempt_started(auth, request_id, route, attempt_no)
            .await
        {
            Ok(attempt_id) => attempt_id,
            Err(error) => {
                finish_request_with_error(
                    repository,
                    auth,
                    request_id,
                    request_started_at,
                    error.log_summary(),
                )
                .await;
                return error.into_response();
            }
        };

        let provider_started_at = Instant::now();
        let upstream_client = match cached_openai_client(upstream_clients, &route.endpoint) {
            Ok(client) => client,
            Err(error) => {
                let summary = summarize_adapter_error(&error);
                finish_provider_attempt_with_adapter_error(
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                )
                .await;
                finish_request_with_error(
                    repository,
                    auth,
                    request_id,
                    request_started_at,
                    summary,
                )
                .await;
                return adapter_error_response(error);
            }
        };
        let upstream_request = request_for_upstream(request, &route.upstream_model);

        let provider_key = match open_provider_key_for_route(repository, auth, route).await {
            Ok(provider_key) => provider_key,
            Err(error) => {
                finish_provider_attempt_with_error(
                    repository,
                    auth,
                    attempt_id,
                    provider_started_at,
                    error.log_summary(),
                )
                .await;
                finish_request_with_error(
                    repository,
                    auth,
                    request_id,
                    request_started_at,
                    error.log_summary(),
                )
                .await;
                return error.into_response();
            }
        };

        match upstream_client
            .chat_completions_stream_with_provider_key(
                &upstream_request,
                Some(provider_key.secret.expose_secret()),
            )
            .await
        {
            Ok(upstream_stream) => {
                if !upstream_stream
                    .content_type()
                    .is_some_and(|content_type| content_type.starts_with("text/event-stream"))
                {
                    tracing::warn!(
                        provider_id = %route.provider_id,
                        channel_id = %route.channel_id,
                        content_type = upstream_stream.content_type().unwrap_or("<missing>"),
                        "upstream chat stream did not declare text/event-stream"
                    );
                }

                record_request_final_route(
                    repository,
                    auth,
                    request_id,
                    route,
                    route_snapshot_with_final_attempt(
                        route_snapshot.clone(),
                        route,
                        attempt_no,
                        &fallback_events,
                    ),
                )
                .await;

                return stream_response(
                    upstream_stream,
                    StreamLogContext {
                        repository: repository.clone(),
                        auth: auth.clone(),
                        request_id,
                        attempt_id,
                        canonical_model_id: route.canonical_model_id,
                        canonical_model_key: route.canonical_model_key.clone(),
                        request_started_at,
                        provider_started_at,
                    },
                );
            }
            Err(error) => {
                let summary = summarize_adapter_error(&error);

                if attempt_index + 1 < attempt_routes.len() && provider_error_can_fallback(&error) {
                    let next_route = &attempt_routes[attempt_index + 1];
                    let event = fallback_event(attempt_no, &summary, route, next_route);
                    finish_provider_attempt_with_adapter_error_and_fallback(
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        Some(summary.error_code.as_str()),
                        provider_attempt_fallback_metadata(&event),
                    )
                    .await;
                    fallback_events.push(event);

                    tracing::warn!(
                        attempt_no,
                        provider_id = %route.provider_id,
                        channel_id = %route.channel_id,
                        error_code = %summary.error_code,
                        "provider stream attempt failed before response started; trying fallback route"
                    );
                    continue;
                }

                finish_provider_attempt_with_adapter_error(
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                )
                .await;
                finish_request_with_error(
                    repository,
                    auth,
                    request_id,
                    request_started_at,
                    summary,
                )
                .await;
                return adapter_error_response(error);
            }
        }
    }

    unreachable!("non-empty provider attempt loop must return a response");
}

#[derive(Debug, Clone)]
struct StreamLogContext {
    repository: GatewayRepository,
    auth: AuthContext,
    request_id: uuid::Uuid,
    attempt_id: uuid::Uuid,
    canonical_model_id: uuid::Uuid,
    canonical_model_key: String,
    request_started_at: Instant,
    provider_started_at: Instant,
}

fn stream_response(upstream: OpenAiChatStream, context: StreamLogContext) -> Response {
    let status = StatusCode::from_u16(upstream.status()).unwrap_or(StatusCode::OK);
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-cache"));

    let state = ForwardStreamState::new(upstream, context);
    // Hyper polls this stream under socket backpressure, so each downstream poll performs at
    // most one upstream read. The chunk guard below caps per-poll parser memory.
    let body = Body::from_stream(stream::unfold(Some(state), |state| async move {
        let mut state = state?;

        match state.upstream.next_chunk().await {
            Ok(Some(chunk)) => match state.observe_chunk(&chunk) {
                Ok(()) => Some((Ok(Bytes::from(chunk)), Some(state))),
                Err(error) => {
                    let contract =
                        stream_forward_failure_contract(StreamForwardFailureKind::from(&error));
                    debug_assert!(!contract.allow_late_fallback);
                    tracing::warn!(
                        %error,
                        partial_sent = state.partial_sent(),
                        "failed to parse upstream SSE chunk while forwarding chat stream"
                    );
                    state.finish(contract.end_reason).await;
                    Some((Err(stream_io_error(contract.end_reason)), None))
                }
            },
            Err(error) => {
                let contract =
                    stream_forward_failure_contract(StreamForwardFailureKind::UpstreamReadError);
                debug_assert!(!contract.allow_late_fallback);
                // The downstream response has already been built, so this scaffold records the
                // failure and closes the stream instead of attempting a late fallback.
                tracing::warn!(
                    %error,
                    partial_sent = state.partial_sent(),
                    "upstream chat stream failed after response started; not attempting fallback"
                );
                state.finish(contract.end_reason).await;
                Some((Err(stream_io_error(contract.end_reason)), None))
            }
            Ok(None) => {
                let end_reason = match state.observe_eof() {
                    Ok(end_reason) => end_reason,
                    Err(error) => {
                        tracing::warn!(
                            %error,
                            partial_sent = state.partial_sent(),
                            "failed to parse trailing upstream SSE bytes at EOF"
                        );
                        StreamEndReason::ParserError
                    }
                };
                state.finish(end_reason).await;
                None
            }
        }
    }));

    (status, headers, body).into_response()
}

struct ForwardStreamState {
    upstream: OpenAiChatStream,
    progress: StreamProgress,
    context: StreamLogContext,
    finalization_claim: StreamFinalizationClaim,
}

impl ForwardStreamState {
    fn new(upstream: OpenAiChatStream, context: StreamLogContext) -> Self {
        Self {
            upstream,
            progress: StreamProgress::new(
                OPENAI_STREAM_MAX_EVENT_BYTES,
                OPENAI_STREAM_MAX_CHUNK_BYTES,
            ),
            context,
            finalization_claim: StreamFinalizationClaim::new(),
        }
    }

    fn observe_chunk(&mut self, chunk: &[u8]) -> Result<(), StreamChunkError> {
        self.progress.observe_chunk(
            chunk,
            self.context.request_started_at,
            self.context.provider_started_at,
        )
    }

    fn observe_eof(&mut self) -> Result<StreamEndReason, StreamChunkError> {
        self.progress.observe_eof(
            self.context.request_started_at,
            self.context.provider_started_at,
        )
    }

    fn partial_sent(&self) -> bool {
        self.progress.partial_sent
    }

    async fn finish(self, end_reason: StreamEndReason) {
        let snapshot = self.finalization_snapshot();
        if !self.finalization_claim.try_claim() {
            return;
        }

        let handle = tokio::spawn(async move {
            snapshot.finish(end_reason).await;
        });

        if let Err(error) = handle.await {
            tracing::warn!(%error, "stream finalizer task failed");
        }
    }

    fn finalization_snapshot(&self) -> StreamFinalizationSnapshot {
        StreamFinalizationSnapshot {
            context: self.context.clone(),
            partial_sent: self.progress.partial_sent,
            request_ttft_ms: self.progress.request_ttft_ms,
            provider_ttft_ms: self.progress.provider_ttft_ms,
            usage: self.progress.usage,
        }
    }
}

struct StreamProgress {
    decoder: SseDecoder,
    max_chunk_bytes: usize,
    partial_sent: bool,
    request_ttft_ms: Option<i32>,
    provider_ttft_ms: Option<i32>,
    terminal_kind: TerminalEventKind,
    usage: StreamUsageUpdate,
}

impl StreamProgress {
    fn new(max_event_bytes: usize, max_chunk_bytes: usize) -> Self {
        Self {
            decoder: SseDecoder::new(max_event_bytes),
            max_chunk_bytes,
            partial_sent: false,
            request_ttft_ms: None,
            provider_ttft_ms: None,
            terminal_kind: TerminalEventKind::None,
            usage: StreamUsageUpdate::default(),
        }
    }

    fn observe_chunk(
        &mut self,
        chunk: &[u8],
        request_started_at: Instant,
        provider_started_at: Instant,
    ) -> Result<(), StreamChunkError> {
        if chunk.len() > self.max_chunk_bytes {
            return Err(StreamChunkError::ChunkTooLarge {
                len: chunk.len(),
                max: self.max_chunk_bytes,
            });
        }

        for event in self.decoder.push(chunk)? {
            self.observe_event(&event, request_started_at, provider_started_at);
        }
        Ok(())
    }

    fn observe_eof(
        &mut self,
        request_started_at: Instant,
        provider_started_at: Instant,
    ) -> Result<StreamEndReason, StreamChunkError> {
        for event in self.decoder.finish()? {
            self.observe_event(&event, request_started_at, provider_started_at);
        }

        Ok(stream_end_reason_for_terminal_kind(
            self.terminal_kind,
            StreamEndSignal::UpstreamEof,
        ))
    }

    fn observe_event(
        &mut self,
        event: &SseEvent,
        request_started_at: Instant,
        provider_started_at: Instant,
    ) {
        let terminal_kind = terminal_event_kind(StreamProtocol::OpenAiChatCompletions, event);
        if terminal_kind.is_terminal() {
            self.terminal_kind = terminal_kind;
            return;
        }

        if !event.data.is_empty() && !self.partial_sent {
            self.partial_sent = true;
            self.request_ttft_ms = Some(elapsed_ms(request_started_at));
            self.provider_ttft_ms = Some(elapsed_ms(provider_started_at));
        }

        if let Some(usage) = openai_stream_usage_from_event(event) {
            self.usage = usage;
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum StreamChunkError {
    Decode(SseDecodeError),
    ChunkTooLarge { len: usize, max: usize },
}

impl From<SseDecodeError> for StreamChunkError {
    fn from(error: SseDecodeError) -> Self {
        Self::Decode(error)
    }
}

impl fmt::Display for StreamChunkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode(error) => write!(formatter, "{error}"),
            Self::ChunkTooLarge { len, max } => write!(
                formatter,
                "upstream SSE chunk exceeds backpressure limit: {len} bytes > {max} bytes"
            ),
        }
    }
}

impl std::error::Error for StreamChunkError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StreamEndContract {
    end_reason: StreamEndReason,
    allow_late_fallback: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamForwardFailureKind {
    UpstreamReadError,
    DecodeError,
    ChunkTooLarge,
}

impl From<&StreamChunkError> for StreamForwardFailureKind {
    fn from(error: &StreamChunkError) -> Self {
        match error {
            StreamChunkError::Decode(_) => Self::DecodeError,
            StreamChunkError::ChunkTooLarge { .. } => Self::ChunkTooLarge,
        }
    }
}

const fn stream_forward_failure_contract(failure: StreamForwardFailureKind) -> StreamEndContract {
    let end_reason = match failure {
        StreamForwardFailureKind::UpstreamReadError => StreamEndReason::UpstreamError,
        StreamForwardFailureKind::DecodeError | StreamForwardFailureKind::ChunkTooLarge => {
            StreamEndReason::ParserError
        }
    };

    StreamEndContract {
        end_reason,
        allow_late_fallback: false,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamDownstreamCloseKind {
    BodyDropped,
}

const fn stream_downstream_close_contract(_close: StreamDownstreamCloseKind) -> StreamEndContract {
    StreamEndContract {
        end_reason: StreamEndReason::ClientCancel,
        allow_late_fallback: false,
    }
}

impl Drop for ForwardStreamState {
    fn drop(&mut self) {
        if !self.finalization_claim.try_claim() {
            return;
        }

        let snapshot = self.finalization_snapshot();
        let contract = stream_downstream_close_contract(StreamDownstreamCloseKind::BodyDropped);
        debug_assert!(!contract.allow_late_fallback);
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                // Hyper drops the body stream when the client disconnects or a downstream write
                // fails, which is the only reliable signal available after response start.
                handle.spawn(async move {
                    snapshot.finish(contract.end_reason).await;
                });
            }
            Err(error) => {
                tracing::warn!(
                    %error,
                    "failed to spawn stream client-cancel finalizer without an active runtime"
                );
            }
        }
    }
}

#[derive(Debug, Clone)]
struct StreamFinalizationClaim {
    claimed: Arc<AtomicBool>,
}

impl StreamFinalizationClaim {
    fn new() -> Self {
        Self {
            claimed: Arc::new(AtomicBool::new(false)),
        }
    }

    fn try_claim(&self) -> bool {
        !self.claimed.swap(true, Ordering::AcqRel)
    }
}

#[derive(Debug, Clone)]
struct StreamFinalizationSnapshot {
    context: StreamLogContext,
    partial_sent: bool,
    request_ttft_ms: Option<i32>,
    provider_ttft_ms: Option<i32>,
    usage: StreamUsageUpdate,
}

impl StreamFinalizationSnapshot {
    async fn finish(self, end_reason: StreamEndReason) {
        let rating = match end_reason {
            StreamEndReason::Completed => {
                rate_stream_request_usage(
                    &self.context.repository,
                    &self.context.auth,
                    self.context.canonical_model_id,
                    self.usage,
                )
                .await
            }
            _ => None,
        };

        let request_update = stream_request_final_update(
            elapsed_ms(self.context.request_started_at),
            self.partial_sent,
            end_reason,
            self.request_ttft_ms,
            self.usage,
            rating.clone(),
        );
        record_endpoint_request_final_metrics(EndpointRequestFinalMetrics {
            endpoint: crate::METRICS_ENDPOINT_CHAT_COMPLETIONS,
            outcome: request_update.status,
            http_status: request_update.http_status,
            error_owner: request_update.error_owner.as_deref(),
            error_code: request_update.error_code.as_deref(),
            retryable: request_update.retryable,
            latency_ms: request_update.latency_ms,
            ttft_ms: request_update.ttft_ms,
            final_cost: request_update.final_cost.as_deref(),
            currency: request_update.currency.as_deref(),
        });
        if let Err(error) = self
            .context
            .repository
            .finish_stream_request(&self.context.auth, self.context.request_id, request_update)
            .await
        {
            tracing::warn!(message = %error.message, "failed to finish stream request log");
        }

        settle_stream_request_ledger(
            &self.context.repository,
            &self.context.auth,
            self.context.request_id,
            &self.context.canonical_model_key,
            end_reason,
            self.usage,
            rating.as_ref(),
        )
        .await;

        let provider_update = stream_provider_attempt_final_update(
            elapsed_ms(self.context.provider_started_at),
            end_reason,
            self.provider_ttft_ms,
        );
        if let Err(error) = self
            .context
            .repository
            .finish_stream_provider_attempt(
                &self.context.auth,
                self.context.attempt_id,
                provider_update,
            )
            .await
        {
            tracing::warn!(message = %error.message, "failed to finish stream provider attempt log");
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct StreamUsageUpdate {
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
}

impl StreamUsageUpdate {
    fn is_complete(self) -> bool {
        self.input_tokens.is_some() && self.output_tokens.is_some()
    }

    fn token_usage_for_rating(self) -> Option<TokenUsage> {
        Some(TokenUsage::new(
            self.input_tokens?.try_into().ok()?,
            self.output_tokens?.try_into().ok()?,
        ))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StreamRatingUpdate {
    final_cost: String,
    currency: String,
    price_version_id: uuid::Uuid,
}

fn openai_stream_usage_from_event(event: &SseEvent) -> Option<StreamUsageUpdate> {
    if event.data.is_empty() {
        return None;
    }

    let payload: Value = serde_json::from_slice(&event.data).ok()?;
    openai_stream_usage_from_value(&payload)
}

fn openai_stream_usage_from_value(payload: &Value) -> Option<StreamUsageUpdate> {
    let usage = payload.get("usage")?;
    if usage.is_null() {
        return None;
    }

    let update = StreamUsageUpdate {
        input_tokens: usage
            .get("prompt_tokens")
            .and_then(Value::as_u64)
            .and_then(u64_to_i64),
        output_tokens: usage
            .get("completion_tokens")
            .and_then(Value::as_u64)
            .and_then(u64_to_i64),
    };

    if update.input_tokens.is_some() || update.output_tokens.is_some() {
        Some(update)
    } else {
        None
    }
}

fn u64_to_i64(value: u64) -> Option<i64> {
    i64::try_from(value).ok()
}

async fn rate_stream_request_usage(
    repository: &GatewayRepository,
    auth: &AuthContext,
    canonical_model_id: uuid::Uuid,
    usage: StreamUsageUpdate,
) -> Option<StreamRatingUpdate> {
    let token_usage = usage.token_usage_for_rating()?;

    let price_version = match repository
        .resolve_active_price_version(auth, canonical_model_id)
        .await
    {
        Ok(Some(price_version)) => price_version,
        Ok(None) => return None,
        Err(error) => {
            tracing::warn!(
                message = %error.message,
                "failed to resolve price version for stream request rating"
            );
            return None;
        }
    };

    stream_rating_from_price_version(&price_version, token_usage)
}

fn stream_rating_from_price_version(
    price_version: &ResolvedPriceVersion,
    usage: TokenUsage,
) -> Option<StreamRatingUpdate> {
    let rating = match rate_usage_from_json(&price_version.pricing_rules_json, usage) {
        Ok(rating) => rating,
        Err(error) => {
            tracing::warn!(
                %error,
                price_version_id = %price_version.id,
                "failed to rate stream request usage"
            );
            return None;
        }
    };

    Some(StreamRatingUpdate {
        final_cost: rating.total_cost.to_string(),
        currency: rating.currency,
        price_version_id: price_version.id,
    })
}

fn stream_request_final_update(
    latency_ms: i32,
    partial_sent: bool,
    end_reason: StreamEndReason,
    ttft_ms: Option<i32>,
    usage: StreamUsageUpdate,
    rating: Option<StreamRatingUpdate>,
) -> StreamRequestFinalUpdate {
    let outcome = StreamLogOutcome::from_end_reason(end_reason);
    let usage = match end_reason {
        StreamEndReason::Completed if usage.is_complete() => usage,
        _ => StreamUsageUpdate::default(),
    };
    let rating = if usage.is_complete() { rating } else { None };

    StreamRequestFinalUpdate {
        status: stream_request_status(partial_sent, end_reason, outcome.status),
        http_status: outcome.http_status,
        error_owner: outcome.error_owner.map(str::to_string),
        error_code: outcome.error_code.map(str::to_string),
        retryable: outcome.retryable,
        latency_ms,
        partial_sent,
        stream_end_reason: end_reason.as_str(),
        ttft_ms,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        final_cost: rating.as_ref().map(|rating| rating.final_cost.clone()),
        currency: rating.as_ref().map(|rating| rating.currency.clone()),
        price_version_id: rating.map(|rating| rating.price_version_id),
        response_body_hash: None,
    }
}

async fn settle_stream_request_ledger(
    repository: &GatewayRepository,
    auth: &AuthContext,
    request_id: uuid::Uuid,
    model: &str,
    end_reason: StreamEndReason,
    usage: StreamUsageUpdate,
    rating: Option<&StreamRatingUpdate>,
) {
    let Some(entry) = stream_ledger_settle_entry(request_id, model, end_reason, usage, rating)
    else {
        return;
    };

    if let Err(error) = repository
        .insert_confirmed_settle_ledger_entry(auth, entry)
        .await
    {
        tracing::warn!(
            message = %error.message,
            "failed to insert stream settle ledger entry"
        );
    }
}

fn stream_ledger_settle_entry<'a>(
    request_id: uuid::Uuid,
    model: &'a str,
    end_reason: StreamEndReason,
    usage: StreamUsageUpdate,
    rating: Option<&'a StreamRatingUpdate>,
) -> Option<LedgerSettleEntry<'a>> {
    if !matches!(end_reason, StreamEndReason::Completed) {
        return None;
    }

    let rating = rating?;
    let input_tokens = usage.input_tokens?;
    let output_tokens = usage.output_tokens?;

    crate::db::settle_ledger_amount(&rating.final_cost)?;

    Some(LedgerSettleEntry {
        request_id,
        model,
        final_cost: &rating.final_cost,
        currency: &rating.currency,
        price_version_id: rating.price_version_id,
        input_tokens,
        output_tokens,
    })
}

fn stream_request_status(
    partial_sent: bool,
    end_reason: StreamEndReason,
    fallback_status: &'static str,
) -> &'static str {
    match end_reason {
        StreamEndReason::Completed => "succeeded",
        StreamEndReason::ClientCancel => "cancelled",
        _ if partial_sent => "partial",
        _ => fallback_status,
    }
}

fn stream_provider_attempt_final_update(
    latency_ms: i32,
    end_reason: StreamEndReason,
    ttft_ms: Option<i32>,
) -> StreamProviderAttemptFinalUpdate {
    let outcome = StreamLogOutcome::from_end_reason(end_reason);

    StreamProviderAttemptFinalUpdate {
        status: outcome.status,
        http_status: outcome.http_status,
        error_owner: outcome.error_owner.map(str::to_string),
        error_code: outcome.error_code.map(str::to_string),
        retryable: outcome.retryable,
        fallback_reason: None,
        latency_ms,
        ttft_ms,
        metadata: json!({}),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StreamLogOutcome {
    status: &'static str,
    http_status: i32,
    error_owner: Option<&'static str>,
    error_code: Option<&'static str>,
    retryable: Option<bool>,
}

impl StreamLogOutcome {
    const fn from_end_reason(end_reason: StreamEndReason) -> Self {
        match end_reason {
            StreamEndReason::Completed => Self {
                status: "succeeded",
                http_status: 200,
                error_owner: None,
                error_code: None,
                retryable: None,
            },
            StreamEndReason::ClientCancel => Self {
                status: "cancelled",
                http_status: 499,
                error_owner: Some("client"),
                error_code: Some("stream_client_cancel"),
                retryable: Some(false),
            },
            StreamEndReason::UpstreamEof => Self {
                status: "failed",
                http_status: 502,
                error_owner: Some("provider"),
                error_code: Some("stream_upstream_eof"),
                retryable: Some(true),
            },
            StreamEndReason::UpstreamError => Self {
                status: "failed",
                http_status: 502,
                error_owner: Some("network"),
                error_code: Some("stream_upstream_error"),
                retryable: Some(true),
            },
            StreamEndReason::ParserError => Self {
                status: "failed",
                http_status: 502,
                error_owner: Some("parser"),
                error_code: Some("stream_parser_error"),
                retryable: Some(true),
            },
            StreamEndReason::Timeout => Self {
                status: "failed",
                http_status: 504,
                error_owner: Some("network"),
                error_code: Some("stream_timeout"),
                retryable: Some(true),
            },
            StreamEndReason::GatewayAbort => Self {
                status: "failed",
                http_status: 500,
                error_owner: Some("gateway"),
                error_code: Some("stream_gateway_abort"),
                retryable: Some(true),
            },
        }
    }
}

fn stream_io_error(end_reason: StreamEndReason) -> io::Error {
    io::Error::other(format!("chat stream ended with {}", end_reason.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_final_update_payload_records_completed_partial_ttft() {
        let update = stream_request_final_update(
            37,
            true,
            StreamEndReason::Completed,
            Some(12),
            StreamUsageUpdate::default(),
            None,
        );

        assert_eq!(update.status, "succeeded");
        assert_eq!(update.http_status, 200);
        assert_eq!(update.error_owner, None);
        assert_eq!(update.error_code, None);
        assert_eq!(update.latency_ms, 37);
        assert!(update.partial_sent);
        assert_eq!(update.stream_end_reason, "completed");
        assert_eq!(update.ttft_ms, Some(12));
        assert_eq!(update.input_tokens, None);
        assert_eq!(update.final_cost, None);
    }

    #[test]
    fn stream_final_update_payload_records_missing_done_failure() {
        let update = stream_request_final_update(
            41,
            true,
            StreamEndReason::UpstreamEof,
            Some(9),
            StreamUsageUpdate::default(),
            None,
        );

        assert_eq!(update.status, "partial");
        assert_eq!(update.http_status, 502);
        assert_eq!(update.error_owner.as_deref(), Some("provider"));
        assert_eq!(update.error_code.as_deref(), Some("stream_upstream_eof"));
        assert_eq!(update.retryable, Some(true));
        assert_eq!(update.stream_end_reason, "upstream_eof");
        assert_eq!(update.ttft_ms, Some(9));
    }

    #[test]
    fn stream_final_update_payload_records_preflight_failure_without_partial() {
        let update = stream_request_final_update(
            8,
            false,
            StreamEndReason::UpstreamError,
            None,
            StreamUsageUpdate::default(),
            None,
        );

        assert_eq!(update.status, "failed");
        assert_eq!(update.http_status, 502);
        assert_eq!(update.error_owner.as_deref(), Some("network"));
        assert!(!update.partial_sent);
        assert_eq!(update.stream_end_reason, "upstream_error");
        assert_eq!(update.ttft_ms, None);
        assert_eq!(update.input_tokens, None);
    }

    #[test]
    fn stream_final_update_payload_records_client_cancel() {
        let request = stream_request_final_update(
            11,
            true,
            StreamEndReason::ClientCancel,
            Some(4),
            StreamUsageUpdate::default(),
            None,
        );
        let attempt =
            stream_provider_attempt_final_update(10, StreamEndReason::ClientCancel, Some(3));

        assert_eq!(request.status, "cancelled");
        assert_eq!(request.http_status, 499);
        assert_eq!(request.error_owner.as_deref(), Some("client"));
        assert_eq!(request.error_code.as_deref(), Some("stream_client_cancel"));
        assert_eq!(request.stream_end_reason, "client_cancel");
        assert!(request.partial_sent);
        assert_eq!(attempt.status, "cancelled");
        assert_eq!(attempt.http_status, 499);
        assert_eq!(attempt.error_owner.as_deref(), Some("client"));
        assert_eq!(attempt.error_code.as_deref(), Some("stream_client_cancel"));
    }

    #[test]
    fn stream_final_update_payload_records_downstream_close_without_partial() {
        let request = stream_request_final_update(
            11,
            false,
            StreamEndReason::ClientCancel,
            None,
            StreamUsageUpdate {
                input_tokens: Some(12),
                output_tokens: Some(34),
            },
            Some(StreamRatingUpdate {
                final_cost: "0.00012345".to_string(),
                currency: "USD".to_string(),
                price_version_id: uuid::Uuid::from_u128(41),
            }),
        );
        let attempt = stream_provider_attempt_final_update(10, StreamEndReason::ClientCancel, None);

        assert_eq!(request.status, "cancelled");
        assert_eq!(request.http_status, 499);
        assert_eq!(request.error_owner.as_deref(), Some("client"));
        assert_eq!(request.stream_end_reason, "client_cancel");
        assert!(!request.partial_sent);
        assert_eq!(request.ttft_ms, None);
        assert_eq!(request.input_tokens, None);
        assert_eq!(request.output_tokens, None);
        assert_eq!(request.final_cost, None);
        assert_eq!(attempt.status, "cancelled");
        assert_eq!(attempt.http_status, 499);
        assert_eq!(attempt.ttft_ms, None);
    }

    #[test]
    fn stream_final_update_payload_records_partial_then_upstream_failure() {
        let request = stream_request_final_update(
            29,
            true,
            StreamEndReason::UpstreamError,
            Some(6),
            StreamUsageUpdate {
                input_tokens: Some(12),
                output_tokens: Some(34),
            },
            Some(StreamRatingUpdate {
                final_cost: "0.00012345".to_string(),
                currency: "USD".to_string(),
                price_version_id: uuid::Uuid::from_u128(42),
            }),
        );
        let attempt =
            stream_provider_attempt_final_update(28, StreamEndReason::UpstreamError, Some(5));

        assert_eq!(request.status, "partial");
        assert_eq!(request.http_status, 502);
        assert_eq!(request.error_owner.as_deref(), Some("network"));
        assert_eq!(request.error_code.as_deref(), Some("stream_upstream_error"));
        assert_eq!(request.retryable, Some(true));
        assert!(request.partial_sent);
        assert_eq!(request.stream_end_reason, "upstream_error");
        assert_eq!(request.ttft_ms, Some(6));
        assert_eq!(request.input_tokens, None);
        assert_eq!(request.output_tokens, None);
        assert_eq!(request.final_cost, None);
        assert_eq!(attempt.status, "failed");
        assert_eq!(attempt.error_code.as_deref(), Some("stream_upstream_error"));
        assert_eq!(attempt.ttft_ms, Some(5));
    }

    #[test]
    fn stream_progress_tracks_partial_usage_and_terminal_done() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut progress = StreamProgress::new(1024, 1024);

        progress
            .observe_chunk(
                b"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
                request_started_at,
                provider_started_at,
            )
            .expect("content chunk should parse");
        progress
            .observe_chunk(
                b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n",
                request_started_at,
                provider_started_at,
            )
            .expect("usage and done chunk should parse");

        assert!(progress.partial_sent);
        assert!(progress.request_ttft_ms.is_some());
        assert!(progress.provider_ttft_ms.is_some());
        assert_eq!(
            progress.usage,
            StreamUsageUpdate {
                input_tokens: Some(2),
                output_tokens: Some(3),
            }
        );
        assert_eq!(progress.terminal_kind, TerminalEventKind::Completed);
        assert_eq!(
            progress
                .observe_eof(request_started_at, provider_started_at)
                .expect("clean EOF should classify"),
            StreamEndReason::Completed
        );
    }

    #[test]
    fn stream_progress_rejects_oversized_chunk_before_mutating_progress() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut progress = StreamProgress::new(1024, 8);

        let error = progress
            .observe_chunk(b"data: 123\n\n", request_started_at, provider_started_at)
            .expect_err("chunk guard should reject oversized chunks");

        assert_eq!(error, StreamChunkError::ChunkTooLarge { len: 11, max: 8 });
        assert!(!progress.partial_sent);
        assert_eq!(progress.request_ttft_ms, None);
        assert_eq!(progress.terminal_kind, TerminalEventKind::None);
    }

    #[test]
    fn stream_forward_failure_contract_disables_late_fallback_after_response_start() {
        for (failure, expected_end_reason) in [
            (
                StreamForwardFailureKind::UpstreamReadError,
                StreamEndReason::UpstreamError,
            ),
            (
                StreamForwardFailureKind::DecodeError,
                StreamEndReason::ParserError,
            ),
            (
                StreamForwardFailureKind::ChunkTooLarge,
                StreamEndReason::ParserError,
            ),
        ] {
            let contract = stream_forward_failure_contract(failure);

            assert_eq!(contract.end_reason, expected_end_reason);
            assert!(!contract.allow_late_fallback);
        }
    }

    #[test]
    fn stream_chunk_error_classifies_bounded_buffer_failures() {
        let decode_error = StreamChunkError::Decode(SseDecodeError::BufferTooLarge);
        let oversized_error = StreamChunkError::ChunkTooLarge { len: 11, max: 8 };

        assert_eq!(
            StreamForwardFailureKind::from(&decode_error),
            StreamForwardFailureKind::DecodeError
        );
        assert_eq!(
            StreamForwardFailureKind::from(&oversized_error),
            StreamForwardFailureKind::ChunkTooLarge
        );
        assert_eq!(
            stream_forward_failure_contract(StreamForwardFailureKind::from(&oversized_error))
                .end_reason,
            StreamEndReason::ParserError
        );
    }

    #[test]
    fn downstream_body_drop_contract_maps_send_failure_to_client_cancel() {
        let contract = stream_downstream_close_contract(StreamDownstreamCloseKind::BodyDropped);

        assert_eq!(contract.end_reason, StreamEndReason::ClientCancel);
        assert!(!contract.allow_late_fallback);
    }

    #[test]
    fn openai_stream_usage_chunk_extracts_prompt_and_completion_tokens() {
        let event = SseEvent {
            event: None,
            data: Bytes::from_static(
                br#"{"id":"chatcmpl_1","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34,"total_tokens":46}}"#,
            ),
        };

        let usage = openai_stream_usage_from_event(&event).expect("usage chunk should parse");

        assert_eq!(
            usage,
            StreamUsageUpdate {
                input_tokens: Some(12),
                output_tokens: Some(34),
            }
        );
        assert_eq!(
            usage.token_usage_for_rating(),
            Some(TokenUsage::new(12, 34))
        );
    }

    #[test]
    fn openai_stream_usage_observation_ignores_missing_or_non_json_usage() {
        let null_usage = openai_stream_usage_from_value(&json!({ "usage": null }));
        let no_usage = openai_stream_usage_from_value(&json!({ "choices": [] }));
        let invalid_json = openai_stream_usage_from_event(&SseEvent {
            event: None,
            data: Bytes::from_static(b"{not-json"),
        });

        assert_eq!(null_usage, None);
        assert_eq!(no_usage, None);
        assert_eq!(invalid_json, None);
    }

    #[test]
    fn completed_stream_final_update_carries_complete_usage_and_rating() {
        let price_version_id = uuid::Uuid::from_u128(30);
        let update = stream_request_final_update(
            37,
            true,
            StreamEndReason::Completed,
            Some(12),
            StreamUsageUpdate {
                input_tokens: Some(12),
                output_tokens: Some(34),
            },
            Some(StreamRatingUpdate {
                final_cost: "0.00012345".to_string(),
                currency: "USD".to_string(),
                price_version_id,
            }),
        );

        assert_eq!(update.input_tokens, Some(12));
        assert_eq!(update.output_tokens, Some(34));
        assert_eq!(update.final_cost.as_deref(), Some("0.00012345"));
        assert_eq!(update.currency.as_deref(), Some("USD"));
        assert_eq!(update.price_version_id, Some(price_version_id));
    }

    #[test]
    fn stream_final_update_omits_usage_for_non_completed_or_incomplete_usage() {
        let observed_usage = StreamUsageUpdate {
            input_tokens: Some(12),
            output_tokens: Some(34),
        };
        let partial_usage = StreamUsageUpdate {
            input_tokens: Some(12),
            output_tokens: None,
        };

        let cancelled = stream_request_final_update(
            37,
            true,
            StreamEndReason::ClientCancel,
            Some(12),
            observed_usage,
            Some(StreamRatingUpdate {
                final_cost: "0.00012345".to_string(),
                currency: "USD".to_string(),
                price_version_id: uuid::Uuid::from_u128(31),
            }),
        );
        let completed_with_partial_usage = stream_request_final_update(
            37,
            true,
            StreamEndReason::Completed,
            Some(12),
            partial_usage,
            Some(StreamRatingUpdate {
                final_cost: "0.00012345".to_string(),
                currency: "USD".to_string(),
                price_version_id: uuid::Uuid::from_u128(32),
            }),
        );

        assert_eq!(cancelled.input_tokens, None);
        assert_eq!(cancelled.output_tokens, None);
        assert_eq!(cancelled.final_cost, None);
        assert_eq!(completed_with_partial_usage.input_tokens, None);
        assert_eq!(completed_with_partial_usage.output_tokens, None);
        assert_eq!(completed_with_partial_usage.final_cost, None);
    }

    #[test]
    fn streaming_usage_completed_final_update_carries_confirmed_rating() {
        let price_version_id = uuid::Uuid::from_u128(34);
        let update = stream_request_final_update(
            37,
            true,
            StreamEndReason::Completed,
            Some(12),
            StreamUsageUpdate {
                input_tokens: Some(12),
                output_tokens: Some(34),
            },
            Some(StreamRatingUpdate {
                final_cost: "0.00012345".to_string(),
                currency: "USD".to_string(),
                price_version_id,
            }),
        );

        assert_eq!(update.status, "succeeded");
        assert_eq!(update.input_tokens, Some(12));
        assert_eq!(update.output_tokens, Some(34));
        assert_eq!(update.final_cost.as_deref(), Some("0.00012345"));
        assert_eq!(update.currency.as_deref(), Some("USD"));
        assert_eq!(update.price_version_id, Some(price_version_id));
    }

    #[test]
    fn streaming_usage_missing_usage_keeps_final_cost_empty_and_skips_settle() {
        let request_id = uuid::Uuid::from_u128(35);
        let price_version_id = uuid::Uuid::from_u128(36);
        let rating = StreamRatingUpdate {
            final_cost: "0.00012345".to_string(),
            currency: "USD".to_string(),
            price_version_id,
        };

        let update = stream_request_final_update(
            37,
            true,
            StreamEndReason::Completed,
            Some(12),
            StreamUsageUpdate::default(),
            Some(rating.clone()),
        );
        let entry = stream_ledger_settle_entry(
            request_id,
            "chat-model",
            StreamEndReason::Completed,
            StreamUsageUpdate::default(),
            Some(&rating),
        );

        assert_eq!(update.status, "succeeded");
        assert_eq!(update.input_tokens, None);
        assert_eq!(update.output_tokens, None);
        assert_eq!(update.final_cost, None);
        assert!(entry.is_none());
    }

    #[test]
    fn streaming_usage_settle_entry_requires_completed_complete_nonzero_rating() {
        let request_id = uuid::Uuid::from_u128(37);
        let price_version_id = uuid::Uuid::from_u128(38);
        let usage = StreamUsageUpdate {
            input_tokens: Some(12),
            output_tokens: Some(34),
        };
        let rating = StreamRatingUpdate {
            final_cost: "0.00012345".to_string(),
            currency: "USD".to_string(),
            price_version_id,
        };
        let zero_rating = StreamRatingUpdate {
            final_cost: "0.00000000".to_string(),
            currency: "USD".to_string(),
            price_version_id,
        };

        let entry = stream_ledger_settle_entry(
            request_id,
            "chat-model",
            StreamEndReason::Completed,
            usage,
            Some(&rating),
        )
        .expect("complete usage should settle");

        assert_eq!(entry.request_id, request_id);
        assert_eq!(entry.model, "chat-model");
        assert_eq!(entry.final_cost, "0.00012345");
        assert_eq!(entry.currency, "USD");
        assert_eq!(entry.price_version_id, price_version_id);
        assert_eq!(entry.input_tokens, 12);
        assert_eq!(entry.output_tokens, 34);
        assert!(
            stream_ledger_settle_entry(
                request_id,
                "chat-model",
                StreamEndReason::ClientCancel,
                usage,
                Some(&rating)
            )
            .is_none()
        );
        assert!(
            stream_ledger_settle_entry(
                request_id,
                "chat-model",
                StreamEndReason::Completed,
                usage,
                Some(&zero_rating)
            )
            .is_none()
        );
    }

    #[test]
    fn rates_stream_usage_from_resolved_price_version() {
        let price_version_id = uuid::Uuid::from_u128(33);
        let price_version = ResolvedPriceVersion {
            id: price_version_id,
            pricing_rules_json: json!({
                "currency": "USD",
                "scale": 8,
                "input_token_rate_per_1m": "1.00000000",
                "output_token_rate_per_1m": "2.00000000",
                "fixed_request_cost": "0.10000000"
            })
            .to_string(),
        };

        let rating =
            stream_rating_from_price_version(&price_version, TokenUsage::new(1_000_000, 500_000))
                .expect("valid price version should rate");

        assert_eq!(rating.final_cost, "2.10000000");
        assert_eq!(rating.currency, "USD");
        assert_eq!(rating.price_version_id, price_version_id);
    }

    #[test]
    fn stream_finalization_claim_allows_exactly_one_finisher() {
        let claim = StreamFinalizationClaim::new();
        let cloned = claim.clone();

        assert!(claim.try_claim());
        assert!(!claim.try_claim());
        assert!(!cloned.try_claim());
    }
}
