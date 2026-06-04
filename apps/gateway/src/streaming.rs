use std::{
    fmt, io,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use ai_gateway_adapters::{
    AdapterUpstreamRequest, AdapterUsage, AnthropicAdapter, AnthropicAdapterError,
    AnthropicMessagesRequest, AnthropicStreamTerminalKind, ChatCompletionRequest, GeminiAdapter,
    GeminiStreamTerminalKind, OpenAiAdapterError, OpenAiChatStream, OpenAiCompatibleClient,
    OpenAiResponseRequest, OpenAiResponsesStreamTerminalKind,
};
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
    EndpointRequestFinalMetrics, GatewayRateLimitReservationAttempt, NativeParsedJsonBody,
    OpenAiClientCache, acquire_gateway_rate_limit_reservation_for_attempt,
    anthropic_provider_error_can_fallback, cached_openai_client,
    db::{
        AuthContext, GatewayRepository, LedgerSettleEntry, ResolvedChatRoute, ResolvedPriceVersion,
        StreamProviderAttemptFinalUpdate, StreamRequestFinalUpdate,
    },
    elapsed_ms,
    errors::{adapter_error_response, summarize_adapter_error},
    errors::{anthropic_adapter_error_response, summarize_anthropic_adapter_error},
    fallback_event, finish_provider_attempt_with_adapter_error_and_fallback,
    finish_provider_attempt_with_adapter_error_and_fallback_for_endpoint,
    finish_provider_attempt_with_adapter_error_with_metadata,
    finish_provider_attempt_with_anthropic_adapter_error_and_fallback_for_endpoint,
    finish_provider_attempt_with_anthropic_adapter_error_with_metadata,
    finish_provider_attempt_with_error_with_metadata, finish_request_with_error,
    finish_request_with_error_for_endpoint, gateway_rate_limit_reservation_for_attempt,
    open_provider_key_for_route, pre_authorize_before_provider_attempt,
    provider_attempt_fallback_metadata, provider_attempt_metadata_with_rate_limit_reservation,
    provider_error_can_fallback, rate_limit_reservation_rejected_error,
    rate_limit_reservation_skip_event, record_endpoint_request_final_metrics,
    record_request_final_route, record_request_rate_limit_reservation_rejection,
    release_gateway_rate_limit_reservation_if_needed, request_for_upstream,
    responses_request_for_upstream, route_snapshot_with_final_attempt,
    validate_anthropic_route_endpoint_for_provider_call, validate_route_endpoint_for_provider_call,
};

const OPENAI_STREAM_MAX_EVENT_BYTES: usize = 4 * 1024 * 1024;
const OPENAI_STREAM_MAX_CHUNK_BYTES: usize = OPENAI_STREAM_MAX_EVENT_BYTES;
const ANTHROPIC_API_KEY_HEADER: &str = "x-api-key";
const ANTHROPIC_VERSION_HEADER: &str = "anthropic-version";
const DEFAULT_ANTHROPIC_VERSION: &str = "2023-06-01";
const APPLICATION_JSON_CONTENT_TYPE: &str = "application/json";

pub(crate) struct StreamingChatContext<'a> {
    pub(crate) repository: &'a GatewayRepository,
    pub(crate) auth: &'a AuthContext,
    pub(crate) request_id: uuid::Uuid,
    pub(crate) request_started_at: Instant,
    pub(crate) request: &'a ChatCompletionRequest,
    pub(crate) attempt_routes: &'a [ResolvedChatRoute],
    pub(crate) upstream_clients: &'a mut OpenAiClientCache,
    pub(crate) upstream_timeout: Duration,
    pub(crate) stream_idle_timeout: Duration,
    pub(crate) route_snapshot: Value,
}

pub(crate) struct StreamingResponsesContext<'a> {
    pub(crate) repository: &'a GatewayRepository,
    pub(crate) auth: &'a AuthContext,
    pub(crate) request_id: uuid::Uuid,
    pub(crate) request_started_at: Instant,
    pub(crate) request: &'a OpenAiResponseRequest,
    pub(crate) attempt_routes: &'a [ResolvedChatRoute],
    pub(crate) upstream_clients: &'a mut OpenAiClientCache,
    pub(crate) upstream_timeout: Duration,
    pub(crate) stream_idle_timeout: Duration,
    pub(crate) route_snapshot: Value,
}

pub(crate) struct StreamingAnthropicMessagesContext<'a> {
    pub(crate) repository: &'a GatewayRepository,
    pub(crate) auth: &'a AuthContext,
    pub(crate) request_id: uuid::Uuid,
    pub(crate) request_started_at: Instant,
    pub(crate) request: &'a AnthropicMessagesRequest,
    pub(crate) attempt_routes: &'a [ResolvedChatRoute],
    pub(crate) native_http: &'a reqwest::Client,
    pub(crate) stream_idle_timeout: Duration,
    pub(crate) route_snapshot: Value,
}

pub(crate) struct StreamingGeminiGenerateContentContext<'a> {
    pub(crate) repository: &'a GatewayRepository,
    pub(crate) auth: &'a AuthContext,
    pub(crate) request_id: uuid::Uuid,
    pub(crate) request_started_at: Instant,
    pub(crate) original_body: Bytes,
    pub(crate) parsed_body: NativeParsedJsonBody,
    pub(crate) attempt_routes: &'a [ResolvedChatRoute],
    pub(crate) native_http: &'a reqwest::Client,
    pub(crate) stream_idle_timeout: Duration,
    pub(crate) route_snapshot: Value,
    pub(crate) inbound_content_type: Option<String>,
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
        upstream_timeout,
        stream_idle_timeout,
        route_snapshot,
    } = context;

    debug_assert!(request.is_streaming());

    let mut fallback_events = Vec::new();
    let mut rate_limit_reservation_rejections = 0usize;

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

        let mut rate_limit_reservation = gateway_rate_limit_reservation_for_attempt(route);
        if let Some(response) = acquire_gateway_rate_limit_reservation_for_attempt(
            crate::METRICS_ENDPOINT_CHAT_COMPLETIONS,
            repository,
            auth,
            request_id,
            request_started_at,
            route,
            &mut rate_limit_reservation,
        )
        .await
        {
            return response;
        }
        if !rate_limit_reservation.executable() {
            rate_limit_reservation_rejections = rate_limit_reservation_rejections.saturating_add(1);
            if let Some(next_route) = attempt_routes.get(attempt_index + 1) {
                fallback_events.push(rate_limit_reservation_skip_event(
                    attempt_no,
                    route,
                    next_route,
                    &rate_limit_reservation,
                ));
                tracing::warn!(
                    attempt_no,
                    provider_id = %route.provider_id,
                    channel_id = %route.channel_id,
                    "rate-limit reservation rejected; trying fallback stream route"
                );
                continue;
            }
            break;
        }

        let attempt_id = match repository
            .create_provider_attempt_started(auth, request_id, route, attempt_no)
            .await
        {
            Ok(attempt_id) => attempt_id,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_request_with_error_for_endpoint(
                    crate::METRICS_ENDPOINT_CHAT_COMPLETIONS,
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
        let upstream_client =
            match cached_openai_client(upstream_clients, &route.endpoint, upstream_timeout).await {
                Ok(client) => client,
                Err(error) => {
                    let summary = summarize_adapter_error(&error);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_adapter_error_with_metadata(
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        provider_attempt_metadata_with_rate_limit_reservation(
                            json!({}),
                            &rate_limit_reservation,
                            "stream_pre_response_error",
                        ),
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
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_error_with_metadata(
                    repository,
                    auth,
                    attempt_id,
                    provider_started_at,
                    error.log_summary(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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
                    upstream_stream.into(),
                    StreamLogContext {
                        repository: repository.clone(),
                        auth: auth.clone(),
                        request_id,
                        attempt_id,
                        canonical_model_id: route.canonical_model_id,
                        canonical_model_key: route.canonical_model_key.clone(),
                        route: route.clone(),
                        protocol: GatewayStreamProtocol::OpenAiChatCompletions,
                        metrics_endpoint: crate::METRICS_ENDPOINT_CHAT_COMPLETIONS,
                        request_started_at,
                        provider_started_at,
                        stream_idle_timeout,
                        rate_limit_reservation,
                    },
                );
            }
            Err(error) => {
                let summary = summarize_adapter_error(&error);

                if attempt_index + 1 < attempt_routes.len() && provider_error_can_fallback(&error) {
                    let next_route = &attempt_routes[attempt_index + 1];
                    let event = fallback_event(attempt_no, &summary, route, next_route);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_adapter_error_and_fallback(
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        Some(summary.error_code.as_str()),
                        provider_attempt_metadata_with_rate_limit_reservation(
                            provider_attempt_fallback_metadata(&event),
                            &rate_limit_reservation,
                            "fallback",
                        ),
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

                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_adapter_error_with_metadata(
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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

    debug_assert!(rate_limit_reservation_rejections > 0);
    let error = rate_limit_reservation_rejected_error(&request.model);
    if let Some(selected_route) = attempt_routes.first() {
        record_request_rate_limit_reservation_rejection(
            repository,
            auth,
            request_id,
            selected_route,
            route_snapshot.clone(),
            attempt_routes.len(),
            rate_limit_reservation_rejections,
            &fallback_events,
        )
        .await;
    }
    finish_request_with_error(
        repository,
        auth,
        request_id,
        request_started_at,
        error.log_summary(),
    )
    .await;
    error.into_response()
}

pub(crate) async fn responses_streaming(context: StreamingResponsesContext<'_>) -> Response {
    let StreamingResponsesContext {
        repository,
        auth,
        request_id,
        request_started_at,
        request,
        attempt_routes,
        upstream_clients,
        upstream_timeout,
        stream_idle_timeout,
        route_snapshot,
    } = context;

    debug_assert!(request.is_streaming());

    let mut fallback_events = Vec::new();
    let mut rate_limit_reservation_rejections = 0usize;

    for (attempt_index, route) in attempt_routes.iter().enumerate() {
        let attempt_no = i32::try_from(attempt_index + 1).unwrap_or(i32::MAX);
        if let Some(response) = pre_authorize_before_provider_attempt(
            crate::METRICS_ENDPOINT_RESPONSES,
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

        let mut rate_limit_reservation = gateway_rate_limit_reservation_for_attempt(route);
        if let Some(response) = acquire_gateway_rate_limit_reservation_for_attempt(
            crate::METRICS_ENDPOINT_RESPONSES,
            repository,
            auth,
            request_id,
            request_started_at,
            route,
            &mut rate_limit_reservation,
        )
        .await
        {
            return response;
        }
        if !rate_limit_reservation.executable() {
            rate_limit_reservation_rejections = rate_limit_reservation_rejections.saturating_add(1);
            if let Some(next_route) = attempt_routes.get(attempt_index + 1) {
                fallback_events.push(rate_limit_reservation_skip_event(
                    attempt_no,
                    route,
                    next_route,
                    &rate_limit_reservation,
                ));
                tracing::warn!(
                    attempt_no,
                    provider_id = %route.provider_id,
                    channel_id = %route.channel_id,
                    "rate-limit reservation rejected; trying fallback stream route"
                );
                continue;
            }
            break;
        }

        let attempt_id = match repository
            .create_provider_attempt_started(auth, request_id, route, attempt_no)
            .await
        {
            Ok(attempt_id) => attempt_id,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_request_with_error_for_endpoint(
                    crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
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
        let upstream_client =
            match cached_openai_client(upstream_clients, &route.endpoint, upstream_timeout).await {
                Ok(client) => client,
                Err(error) => {
                    let summary = summarize_adapter_error(&error);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_adapter_error_with_metadata(
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        provider_attempt_metadata_with_rate_limit_reservation(
                            json!({}),
                            &rate_limit_reservation,
                            "stream_pre_response_error",
                        ),
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
        let upstream_request = responses_request_for_upstream(request, &route.upstream_model);

        let provider_key = match open_provider_key_for_route(repository, auth, route).await {
            Ok(provider_key) => provider_key,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_error_with_metadata(
                    repository,
                    auth,
                    attempt_id,
                    provider_started_at,
                    error.log_summary(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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
            .responses_stream_with_provider_key(
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
                        "upstream responses stream did not declare text/event-stream"
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
                    upstream_stream.into(),
                    StreamLogContext {
                        repository: repository.clone(),
                        auth: auth.clone(),
                        request_id,
                        attempt_id,
                        canonical_model_id: route.canonical_model_id,
                        canonical_model_key: route.canonical_model_key.clone(),
                        route: route.clone(),
                        protocol: GatewayStreamProtocol::OpenAiResponses,
                        metrics_endpoint: crate::METRICS_ENDPOINT_RESPONSES,
                        request_started_at,
                        provider_started_at,
                        stream_idle_timeout,
                        rate_limit_reservation,
                    },
                );
            }
            Err(error) => {
                let summary = summarize_adapter_error(&error);

                if attempt_index + 1 < attempt_routes.len() && provider_error_can_fallback(&error) {
                    let next_route = &attempt_routes[attempt_index + 1];
                    let event = fallback_event(attempt_no, &summary, route, next_route);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_adapter_error_and_fallback(
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        Some(summary.error_code.as_str()),
                        provider_attempt_metadata_with_rate_limit_reservation(
                            provider_attempt_fallback_metadata(&event),
                            &rate_limit_reservation,
                            "fallback",
                        ),
                    )
                    .await;
                    fallback_events.push(event);

                    tracing::warn!(
                        attempt_no,
                        provider_id = %route.provider_id,
                        channel_id = %route.channel_id,
                        error_code = %summary.error_code,
                        "provider responses stream attempt failed before response started; trying fallback route"
                    );
                    continue;
                }

                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_adapter_error_with_metadata(
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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

    debug_assert!(rate_limit_reservation_rejections > 0);
    let error = rate_limit_reservation_rejected_error(&request.model);
    if let Some(selected_route) = attempt_routes.first() {
        record_request_rate_limit_reservation_rejection(
            repository,
            auth,
            request_id,
            selected_route,
            route_snapshot.clone(),
            attempt_routes.len(),
            rate_limit_reservation_rejections,
            &fallback_events,
        )
        .await;
    }
    finish_request_with_error_for_endpoint(
        crate::METRICS_ENDPOINT_RESPONSES,
        repository,
        auth,
        request_id,
        request_started_at,
        error.log_summary(),
    )
    .await;
    error.into_response()
}

pub(crate) async fn anthropic_messages_streaming(
    context: StreamingAnthropicMessagesContext<'_>,
) -> Response {
    let StreamingAnthropicMessagesContext {
        repository,
        auth,
        request_id,
        request_started_at,
        request,
        attempt_routes,
        native_http,
        stream_idle_timeout,
        route_snapshot,
    } = context;

    debug_assert!(request.is_streaming());

    let adapter = AnthropicAdapter::new();
    let mut fallback_events = Vec::new();
    let mut rate_limit_reservation_rejections = 0usize;

    for (attempt_index, route) in attempt_routes.iter().enumerate() {
        let attempt_no = i32::try_from(attempt_index + 1).unwrap_or(i32::MAX);
        if let Some(response) = pre_authorize_before_provider_attempt(
            crate::METRICS_ENDPOINT_ANTHROPIC_MESSAGES,
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

        let mut rate_limit_reservation = gateway_rate_limit_reservation_for_attempt(route);
        if let Some(response) = acquire_gateway_rate_limit_reservation_for_attempt(
            crate::METRICS_ENDPOINT_ANTHROPIC_MESSAGES,
            repository,
            auth,
            request_id,
            request_started_at,
            route,
            &mut rate_limit_reservation,
        )
        .await
        {
            return response;
        }
        if !rate_limit_reservation.executable() {
            rate_limit_reservation_rejections = rate_limit_reservation_rejections.saturating_add(1);
            if let Some(next_route) = attempt_routes.get(attempt_index + 1) {
                fallback_events.push(rate_limit_reservation_skip_event(
                    attempt_no,
                    route,
                    next_route,
                    &rate_limit_reservation,
                ));
                tracing::warn!(
                    attempt_no,
                    provider_id = %route.provider_id,
                    channel_id = %route.channel_id,
                    "rate-limit reservation rejected; trying fallback stream route"
                );
                continue;
            }
            break;
        }

        let attempt_id = match repository
            .create_provider_attempt_started(auth, request_id, route, attempt_no)
            .await
        {
            Ok(attempt_id) => attempt_id,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
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

        let provider_started_at = Instant::now();
        let upstream_request = match anthropic_messages_stream_request_for_upstream(
            &adapter,
            request,
            &route.upstream_model,
        ) {
            Ok(upstream_request) => upstream_request,
            Err(error) => {
                let summary = summarize_anthropic_adapter_error(&error);
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_anthropic_adapter_error_with_metadata(
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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
                return anthropic_adapter_error_response(error);
            }
        };

        if let Err(error) = validate_anthropic_route_endpoint_for_provider_call(route).await {
            let summary = summarize_anthropic_adapter_error(&error);
            release_gateway_rate_limit_reservation_if_needed(
                repository,
                auth,
                route,
                &mut rate_limit_reservation,
            )
            .await;
            finish_provider_attempt_with_anthropic_adapter_error_with_metadata(
                repository,
                auth,
                route,
                attempt_id,
                provider_started_at,
                &error,
                summary.clone(),
                provider_attempt_metadata_with_rate_limit_reservation(
                    json!({}),
                    &rate_limit_reservation,
                    "stream_pre_response_error",
                ),
            )
            .await;
            finish_request_with_error(repository, auth, request_id, request_started_at, summary)
                .await;
            return anthropic_adapter_error_response(error);
        }

        let provider_key = match open_provider_key_for_route(repository, auth, route).await {
            Ok(provider_key) => provider_key,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_error_with_metadata(
                    repository,
                    auth,
                    attempt_id,
                    provider_started_at,
                    error.log_summary(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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

        match send_anthropic_messages_stream_request(
            native_http,
            route,
            &upstream_request,
            provider_key.secret.expose_secret(),
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
                        "upstream anthropic messages stream did not declare text/event-stream"
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
                        route: route.clone(),
                        protocol: GatewayStreamProtocol::AnthropicMessages,
                        metrics_endpoint: crate::METRICS_ENDPOINT_ANTHROPIC_MESSAGES,
                        request_started_at,
                        provider_started_at,
                        stream_idle_timeout,
                        rate_limit_reservation,
                    },
                );
            }
            Err(error) => {
                let summary = summarize_anthropic_adapter_error(&error);

                if attempt_index + 1 < attempt_routes.len()
                    && anthropic_provider_error_can_fallback(&error)
                {
                    let next_route = &attempt_routes[attempt_index + 1];
                    let event = fallback_event(attempt_no, &summary, route, next_route);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_anthropic_adapter_error_and_fallback_for_endpoint(
                        crate::METRICS_ENDPOINT_ANTHROPIC_MESSAGES,
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        Some(summary.error_code.as_str()),
                        provider_attempt_metadata_with_rate_limit_reservation(
                            provider_attempt_fallback_metadata(&event),
                            &rate_limit_reservation,
                            "fallback",
                        ),
                    )
                    .await;
                    fallback_events.push(event);

                    tracing::warn!(
                        attempt_no,
                        provider_id = %route.provider_id,
                        channel_id = %route.channel_id,
                        error_code = %summary.error_code,
                        "provider anthropic messages stream attempt failed before response started; trying fallback route"
                    );
                    continue;
                }

                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_anthropic_adapter_error_with_metadata(
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
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
                return anthropic_adapter_error_response(error);
            }
        }
    }

    debug_assert!(rate_limit_reservation_rejections > 0);
    let error = rate_limit_reservation_rejected_error(&request.model);
    if let Some(selected_route) = attempt_routes.first() {
        record_request_rate_limit_reservation_rejection(
            repository,
            auth,
            request_id,
            selected_route,
            route_snapshot.clone(),
            attempt_routes.len(),
            rate_limit_reservation_rejections,
            &fallback_events,
        )
        .await;
    }
    finish_request_with_error_for_endpoint(
        crate::METRICS_ENDPOINT_ANTHROPIC_MESSAGES,
        repository,
        auth,
        request_id,
        request_started_at,
        error.log_summary(),
    )
    .await;
    error.into_response()
}

pub(crate) async fn gemini_generate_content_streaming(
    context: StreamingGeminiGenerateContentContext<'_>,
) -> Response {
    let StreamingGeminiGenerateContentContext {
        repository,
        auth,
        request_id,
        request_started_at,
        original_body,
        parsed_body,
        attempt_routes,
        native_http,
        stream_idle_timeout,
        route_snapshot,
        inbound_content_type,
    } = context;

    let mut fallback_events = Vec::new();
    let mut rate_limit_reservation_rejections = 0usize;

    for (attempt_index, route) in attempt_routes.iter().enumerate() {
        let attempt_no = i32::try_from(attempt_index + 1).unwrap_or(i32::MAX);
        if let Some(response) = pre_authorize_before_provider_attempt(
            crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
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

        let mut rate_limit_reservation = gateway_rate_limit_reservation_for_attempt(route);
        if let Some(response) = acquire_gateway_rate_limit_reservation_for_attempt(
            crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
            repository,
            auth,
            request_id,
            request_started_at,
            route,
            &mut rate_limit_reservation,
        )
        .await
        {
            return response;
        }
        if !rate_limit_reservation.executable() {
            rate_limit_reservation_rejections = rate_limit_reservation_rejections.saturating_add(1);
            if let Some(next_route) = attempt_routes.get(attempt_index + 1) {
                fallback_events.push(rate_limit_reservation_skip_event(
                    attempt_no,
                    route,
                    next_route,
                    &rate_limit_reservation,
                ));
                tracing::warn!(
                    attempt_no,
                    provider_id = %route.provider_id,
                    channel_id = %route.channel_id,
                    "rate-limit reservation rejected; trying fallback stream route"
                );
                continue;
            }
            break;
        }

        let attempt_id = match repository
            .create_provider_attempt_started(auth, request_id, route, attempt_no)
            .await
        {
            Ok(attempt_id) => attempt_id,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
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

        let provider_started_at = Instant::now();
        let upstream_path =
            match gemini_stream_generate_content_upstream_path(&route.upstream_model) {
                Ok(path) => path,
                Err(error) => {
                    let summary = summarize_adapter_error(&error);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_adapter_error_and_fallback_for_endpoint(
                        crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        None,
                        provider_attempt_metadata_with_rate_limit_reservation(
                            json!({}),
                            &rate_limit_reservation,
                            "stream_pre_response_error",
                        ),
                    )
                    .await;
                    finish_request_with_error_for_endpoint(
                        crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
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
        let upstream_body = match crate::prepare_native_passthrough_body(
            &original_body,
            &parsed_body,
            &route.upstream_model,
        ) {
            Ok(prepared) => prepared,
            Err(error) => {
                let summary = summarize_adapter_error(&error);
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_adapter_error_and_fallback_for_endpoint(
                    crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                    None,
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
                )
                .await;
                finish_request_with_error_for_endpoint(
                    crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
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

        if let Err(error) = validate_route_endpoint_for_provider_call(route).await {
            let summary = summarize_adapter_error(&error);
            release_gateway_rate_limit_reservation_if_needed(
                repository,
                auth,
                route,
                &mut rate_limit_reservation,
            )
            .await;
            finish_provider_attempt_with_adapter_error_and_fallback_for_endpoint(
                crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                repository,
                auth,
                route,
                attempt_id,
                provider_started_at,
                &error,
                summary.clone(),
                None,
                provider_attempt_metadata_with_rate_limit_reservation(
                    json!({}),
                    &rate_limit_reservation,
                    "stream_pre_response_error",
                ),
            )
            .await;
            finish_request_with_error_for_endpoint(
                crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                repository,
                auth,
                request_id,
                request_started_at,
                summary,
            )
            .await;
            return adapter_error_response(error);
        }

        let provider_key = match open_provider_key_for_route(repository, auth, route).await {
            Ok(provider_key) => provider_key,
            Err(error) => {
                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_error_with_metadata(
                    repository,
                    auth,
                    attempt_id,
                    provider_started_at,
                    error.log_summary(),
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
                )
                .await;
                finish_request_with_error_for_endpoint(
                    crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
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

        match send_gemini_generate_content_stream_request(
            native_http,
            route,
            &upstream_path,
            upstream_body.body,
            provider_key.secret.expose_secret(),
            inbound_content_type.as_deref(),
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
                        "upstream gemini generateContent stream did not declare text/event-stream"
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
                        route: route.clone(),
                        protocol: GatewayStreamProtocol::GeminiGenerateContent,
                        metrics_endpoint: crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                        request_started_at,
                        provider_started_at,
                        stream_idle_timeout,
                        rate_limit_reservation,
                    },
                );
            }
            Err(error) => {
                let summary = summarize_adapter_error(&error);

                if attempt_index + 1 < attempt_routes.len() && provider_error_can_fallback(&error) {
                    let next_route = &attempt_routes[attempt_index + 1];
                    let event = fallback_event(attempt_no, &summary, route, next_route);
                    release_gateway_rate_limit_reservation_if_needed(
                        repository,
                        auth,
                        route,
                        &mut rate_limit_reservation,
                    )
                    .await;
                    finish_provider_attempt_with_adapter_error_and_fallback_for_endpoint(
                        crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                        repository,
                        auth,
                        route,
                        attempt_id,
                        provider_started_at,
                        &error,
                        summary.clone(),
                        Some(summary.error_code.as_str()),
                        provider_attempt_metadata_with_rate_limit_reservation(
                            provider_attempt_fallback_metadata(&event),
                            &rate_limit_reservation,
                            "fallback",
                        ),
                    )
                    .await;
                    fallback_events.push(event);

                    tracing::warn!(
                        attempt_no,
                        provider_id = %route.provider_id,
                        channel_id = %route.channel_id,
                        error_code = %summary.error_code,
                        "provider gemini generateContent stream attempt failed before response started; trying fallback route"
                    );
                    continue;
                }

                release_gateway_rate_limit_reservation_if_needed(
                    repository,
                    auth,
                    route,
                    &mut rate_limit_reservation,
                )
                .await;
                finish_provider_attempt_with_adapter_error_and_fallback_for_endpoint(
                    crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
                    repository,
                    auth,
                    route,
                    attempt_id,
                    provider_started_at,
                    &error,
                    summary.clone(),
                    None,
                    provider_attempt_metadata_with_rate_limit_reservation(
                        json!({}),
                        &rate_limit_reservation,
                        "stream_pre_response_error",
                    ),
                )
                .await;
                finish_request_with_error_for_endpoint(
                    crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
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

    debug_assert!(rate_limit_reservation_rejections > 0);
    let error = rate_limit_reservation_rejected_error("");
    if let Some(selected_route) = attempt_routes.first() {
        record_request_rate_limit_reservation_rejection(
            repository,
            auth,
            request_id,
            selected_route,
            route_snapshot.clone(),
            attempt_routes.len(),
            rate_limit_reservation_rejections,
            &fallback_events,
        )
        .await;
    }
    finish_request_with_error_for_endpoint(
        crate::METRICS_ENDPOINT_GEMINI_GENERATE_CONTENT,
        repository,
        auth,
        request_id,
        request_started_at,
        error.log_summary(),
    )
    .await;
    error.into_response()
}

#[derive(Debug, Clone)]
struct StreamLogContext {
    repository: GatewayRepository,
    auth: AuthContext,
    request_id: uuid::Uuid,
    attempt_id: uuid::Uuid,
    canonical_model_id: uuid::Uuid,
    canonical_model_key: String,
    route: ResolvedChatRoute,
    protocol: GatewayStreamProtocol,
    metrics_endpoint: &'static str,
    request_started_at: Instant,
    provider_started_at: Instant,
    stream_idle_timeout: Duration,
    rate_limit_reservation: GatewayRateLimitReservationAttempt,
}

fn stream_response(upstream: GatewayUpstreamStream, context: StreamLogContext) -> Response {
    let status = StatusCode::from_u16(upstream.status()).unwrap_or(StatusCode::OK);
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-cache"));

    let state = ForwardStreamState::new(upstream, context);
    // Hyper polls this stream under socket backpressure, so each downstream poll performs at
    // most one upstream read. The chunk guard below caps per-poll parser memory.
    let body = Body::from_stream(stream::unfold(Some(state), |state| async move {
        let mut state = state?;

        match tokio::time::timeout(
            state.context.stream_idle_timeout,
            state.upstream.next_chunk(),
        )
        .await
        {
            Ok(Ok(Some(chunk))) => match state.observe_chunk(&chunk) {
                Ok(()) => Some((Ok(Bytes::from(chunk)), Some(state))),
                Err(error) => {
                    let contract =
                        stream_forward_failure_contract(StreamForwardFailureKind::from(&error));
                    debug_assert!(!contract.allow_late_fallback);
                    tracing::warn!(
                        %error,
                        partial_sent = state.partial_sent(),
                    "failed to parse upstream SSE chunk while forwarding stream"
                    );
                    state.finish(contract.end_reason).await;
                    Some((Err(stream_io_error(contract.end_reason)), None))
                }
            },
            Ok(Err(error)) => {
                let contract =
                    stream_forward_failure_contract(StreamForwardFailureKind::UpstreamReadError);
                debug_assert!(!contract.allow_late_fallback);
                // The downstream response has already been built, so this scaffold records the
                // failure and closes the stream instead of attempting a late fallback.
                tracing::warn!(
                    %error,
                    partial_sent = state.partial_sent(),
                    "upstream stream failed after response started; not attempting fallback"
                );
                state.finish(contract.end_reason).await;
                Some((Err(stream_io_error(contract.end_reason)), None))
            }
            Ok(Ok(None)) => {
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
            Err(_) => {
                let contract = stream_forward_failure_contract(StreamForwardFailureKind::Timeout);
                debug_assert!(!contract.allow_late_fallback);
                tracing::warn!(
                    partial_sent = state.partial_sent(),
                    "upstream stream idle timeout after response started; not attempting fallback"
                );
                state.finish(contract.end_reason).await;
                Some((Err(stream_io_error(contract.end_reason)), None))
            }
        }
    }));

    (status, headers, body).into_response()
}

struct ForwardStreamState {
    upstream: GatewayUpstreamStream,
    progress: StreamProgress,
    context: StreamLogContext,
    finalization_claim: StreamFinalizationClaim,
}

impl ForwardStreamState {
    fn new(upstream: GatewayUpstreamStream, context: StreamLogContext) -> Self {
        Self {
            upstream,
            progress: StreamProgress::new(
                context.protocol,
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
    protocol: GatewayStreamProtocol,
    decoder: SseDecoder,
    max_chunk_bytes: usize,
    partial_sent: bool,
    request_ttft_ms: Option<i32>,
    provider_ttft_ms: Option<i32>,
    terminal_kind: TerminalEventKind,
    usage: StreamUsageUpdate,
}

impl StreamProgress {
    fn new(
        protocol: GatewayStreamProtocol,
        max_event_bytes: usize,
        max_chunk_bytes: usize,
    ) -> Self {
        Self {
            protocol,
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
            self.observe_event(&event, request_started_at, provider_started_at)?;
        }
        Ok(())
    }

    fn observe_eof(
        &mut self,
        request_started_at: Instant,
        provider_started_at: Instant,
    ) -> Result<StreamEndReason, StreamChunkError> {
        for event in self.decoder.finish()? {
            self.observe_event(&event, request_started_at, provider_started_at)?;
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
    ) -> Result<(), StreamChunkError> {
        let observation = self.protocol.observe_event(event)?;

        if let Some(usage) = observation.usage {
            self.usage = usage;
        }

        let terminal_kind = observation.terminal_kind;
        if terminal_kind.is_terminal() {
            self.terminal_kind = terminal_kind;
            return Ok(());
        }

        if !event.data.is_empty() && !self.partial_sent {
            self.partial_sent = true;
            self.request_ttft_ms = Some(elapsed_ms(request_started_at));
            self.provider_ttft_ms = Some(elapsed_ms(provider_started_at));
        }

        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GatewayStreamProtocol {
    OpenAiChatCompletions,
    OpenAiResponses,
    AnthropicMessages,
    GeminiGenerateContent,
}

impl GatewayStreamProtocol {
    const fn stream_protocol(self) -> StreamProtocol {
        match self {
            Self::OpenAiChatCompletions => StreamProtocol::OpenAiChatCompletions,
            Self::OpenAiResponses => StreamProtocol::OpenAiResponses,
            Self::AnthropicMessages => StreamProtocol::AnthropicMessages,
            Self::GeminiGenerateContent => StreamProtocol::GeminiGenerateContent,
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::OpenAiChatCompletions => "openai_chat_completions",
            Self::OpenAiResponses => "openai_responses",
            Self::AnthropicMessages => "anthropic_messages",
            Self::GeminiGenerateContent => "gemini_generate_content",
        }
    }

    fn observe_event(self, event: &SseEvent) -> Result<StreamEventObservation, StreamChunkError> {
        match self {
            Self::OpenAiChatCompletions => Ok(StreamEventObservation {
                terminal_kind: terminal_event_kind(self.stream_protocol(), event),
                usage: openai_chat_stream_usage_from_event(event),
            }),
            Self::OpenAiResponses => openai_responses_stream_event_observation(event),
            Self::AnthropicMessages => anthropic_messages_stream_event_observation(event),
            Self::GeminiGenerateContent => gemini_generate_content_stream_event_observation(event),
        }
    }
}

impl From<OpenAiChatStream> for GatewayUpstreamStream {
    fn from(stream: OpenAiChatStream) -> Self {
        Self::OpenAi(stream)
    }
}

enum GatewayUpstreamStream {
    OpenAi(OpenAiChatStream),
    Anthropic(NativeSseStream),
    Gemini(NativeSseStream),
}

impl GatewayUpstreamStream {
    fn status(&self) -> u16 {
        match self {
            Self::OpenAi(stream) => stream.status(),
            Self::Anthropic(stream) => stream.status,
            Self::Gemini(stream) => stream.status,
        }
    }

    fn content_type(&self) -> Option<&str> {
        match self {
            Self::OpenAi(stream) => stream.content_type(),
            Self::Anthropic(stream) => stream.content_type.as_deref(),
            Self::Gemini(stream) => stream.content_type.as_deref(),
        }
    }

    async fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, String> {
        match self {
            Self::OpenAi(stream) => stream.next_chunk().await.map_err(|error| error.to_string()),
            Self::Anthropic(stream) => stream.next_chunk().await,
            Self::Gemini(stream) => stream.next_chunk().await,
        }
    }
}

struct NativeSseStream {
    status: u16,
    content_type: Option<String>,
    response: reqwest::Response,
}

impl NativeSseStream {
    async fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, String> {
        self.response
            .chunk()
            .await
            .map(|chunk| chunk.map(|chunk| chunk.to_vec()))
            .map_err(|error| crate::anthropic_reqwest_error(error).to_string())
    }
}

fn anthropic_messages_stream_request_for_upstream(
    adapter: &AnthropicAdapter,
    request: &AnthropicMessagesRequest,
    upstream_model: &str,
) -> Result<AdapterUpstreamRequest, AnthropicAdapterError> {
    let mut request = request.clone();
    request.model = upstream_model.to_string();
    adapter.build_messages_request(&request)
}

async fn send_anthropic_messages_stream_request(
    http: &reqwest::Client,
    route: &ResolvedChatRoute,
    upstream_request: &AdapterUpstreamRequest,
    provider_key: &str,
) -> Result<GatewayUpstreamStream, AnthropicAdapterError> {
    let url = crate::native_upstream_url(&route.endpoint, &upstream_request.path)
        .map_err(|error| AnthropicAdapterError::RequestSerialize(error.to_string()))?;
    let response = http
        .post(url)
        .header(
            ANTHROPIC_API_KEY_HEADER,
            anthropic_provider_key_header(provider_key)?,
        )
        .header(ANTHROPIC_VERSION_HEADER, DEFAULT_ANTHROPIC_VERSION)
        .header(reqwest::header::CONTENT_TYPE, APPLICATION_JSON_CONTENT_TYPE)
        .json(&upstream_request.body)
        .send()
        .await
        .map_err(crate::anthropic_reqwest_error)?;

    let status = response.status();
    let retry_after = crate::native_retry_after_from_headers(response.headers());
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);

    if !status.is_success() {
        let body =
            response
                .bytes()
                .await
                .map_err(|_| AnthropicAdapterError::UpstreamInvalidJson {
                    status: status.as_u16(),
                    message: "failed to read upstream response body".to_string(),
                    retry_after: retry_after.clone(),
                })?;
        crate::anthropic_parse_messages_response(
            status.as_u16(),
            &body,
            retry_after,
            provider_key,
        )?;
        unreachable!("non-success anthropic stream status must parse as an error");
    }

    Ok(GatewayUpstreamStream::Anthropic(NativeSseStream {
        status: status.as_u16(),
        content_type,
        response,
    }))
}

fn gemini_stream_generate_content_upstream_path(
    upstream_model: &str,
) -> Result<String, OpenAiAdapterError> {
    if !crate::native_model_path_value_is_valid(upstream_model) {
        return Err(OpenAiAdapterError::InvalidRequest {
            message: "upstream model path segment is invalid".to_string(),
            param: Some("model"),
        });
    }

    Ok(format!(
        "{}{}{}",
        crate::GEMINI_UPSTREAM_PATH_PREFIX,
        upstream_model,
        ":streamGenerateContent?alt=sse"
    ))
}

async fn send_gemini_generate_content_stream_request(
    http: &reqwest::Client,
    route: &ResolvedChatRoute,
    upstream_path: &str,
    body: Bytes,
    provider_key: &str,
    inbound_content_type: Option<&str>,
) -> Result<GatewayUpstreamStream, OpenAiAdapterError> {
    let url = crate::native_upstream_url(&route.endpoint, upstream_path)?;
    let content_type = inbound_content_type.unwrap_or(APPLICATION_JSON_CONTENT_TYPE);
    let response = http
        .post(url)
        .header(
            crate::GEMINI_API_KEY_HEADER,
            crate::native_provider_key_header(provider_key)?,
        )
        .header(reqwest::header::CONTENT_TYPE, content_type)
        .body(body)
        .send()
        .await
        .map_err(crate::native_reqwest_error)?;

    let status = response.status();
    let retry_after = crate::native_retry_after_from_headers(response.headers());
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);

    if !status.is_success() {
        let body = response
            .bytes()
            .await
            .map_err(|error| OpenAiAdapterError::UpstreamRead(error.to_string()))?;
        return Err(crate::native_upstream_status_error(
            status.as_u16(),
            &body,
            retry_after,
            provider_key,
        ));
    }

    Ok(GatewayUpstreamStream::Gemini(NativeSseStream {
        status: status.as_u16(),
        content_type,
        response,
    }))
}

fn anthropic_provider_key_header(
    provider_key: &str,
) -> Result<reqwest::header::HeaderValue, AnthropicAdapterError> {
    reqwest::header::HeaderValue::from_str(provider_key).map_err(|_| {
        AnthropicAdapterError::RequestSerialize(
            "provider authorization credential is invalid".into(),
        )
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StreamEventObservation {
    terminal_kind: TerminalEventKind,
    usage: Option<StreamUsageUpdate>,
}

impl Default for StreamEventObservation {
    fn default() -> Self {
        Self {
            terminal_kind: TerminalEventKind::None,
            usage: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum StreamChunkError {
    Decode(SseDecodeError),
    ProtocolParser {
        protocol: GatewayStreamProtocol,
        message: String,
    },
    ChunkTooLarge {
        len: usize,
        max: usize,
    },
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
            Self::ProtocolParser { protocol, message } => {
                write!(
                    formatter,
                    "{} stream parser error: {message}",
                    protocol.as_str()
                )
            }
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
    Timeout,
}

impl From<&StreamChunkError> for StreamForwardFailureKind {
    fn from(error: &StreamChunkError) -> Self {
        match error {
            StreamChunkError::Decode(_) => Self::DecodeError,
            StreamChunkError::ProtocolParser { .. } => Self::DecodeError,
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
        StreamForwardFailureKind::Timeout => StreamEndReason::Timeout,
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
    async fn finish(mut self, end_reason: StreamEndReason) {
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
        if end_reason != StreamEndReason::Completed {
            release_gateway_rate_limit_reservation_if_needed(
                &self.context.repository,
                &self.context.auth,
                &self.context.route,
                &mut self.context.rate_limit_reservation,
            )
            .await;
        }

        let request_update = stream_request_final_update(
            elapsed_ms(self.context.request_started_at),
            self.partial_sent,
            end_reason,
            self.request_ttft_ms,
            self.usage,
            rating.clone(),
        );
        record_endpoint_request_final_metrics(EndpointRequestFinalMetrics {
            endpoint: self.context.metrics_endpoint,
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
            provider_attempt_metadata_with_rate_limit_reservation(
                json!({}),
                &self.context.rate_limit_reservation,
                rate_limit_reservation_stream_outcome(end_reason),
            ),
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

fn openai_chat_stream_usage_from_event(event: &SseEvent) -> Option<StreamUsageUpdate> {
    if event.data.is_empty() {
        return None;
    }

    let payload: Value = serde_json::from_slice(&event.data).ok()?;
    openai_stream_usage_from_value(&payload)
}

fn openai_responses_stream_event_observation(
    event: &SseEvent,
) -> Result<StreamEventObservation, StreamChunkError> {
    if event.data.is_empty() {
        return Ok(StreamEventObservation::default());
    }

    let stream_terminal_kind = terminal_event_kind(StreamProtocol::OpenAiResponses, event);
    let adapter_event =
        OpenAiCompatibleClient::parse_responses_stream_event(&event.data).map_err(|error| {
            StreamChunkError::ProtocolParser {
                protocol: GatewayStreamProtocol::OpenAiResponses,
                message: error.to_string(),
            }
        })?;

    Ok(StreamEventObservation {
        terminal_kind: merge_terminal_kinds(
            stream_terminal_kind,
            responses_adapter_terminal_kind(adapter_event.terminal_kind.clone()),
        ),
        usage: adapter_event
            .usage()
            .and_then(stream_usage_from_adapter_usage),
    })
}

fn anthropic_messages_stream_event_observation(
    event: &SseEvent,
) -> Result<StreamEventObservation, StreamChunkError> {
    if event.data.is_empty() {
        return Ok(StreamEventObservation::default());
    }

    let stream_terminal_kind = terminal_event_kind(StreamProtocol::AnthropicMessages, event);
    let adapter_event =
        AnthropicAdapter::parse_messages_stream_event(event.event.as_deref(), &event.data)
            .map_err(|error| StreamChunkError::ProtocolParser {
                protocol: GatewayStreamProtocol::AnthropicMessages,
                message: error.to_string(),
            })?;

    Ok(StreamEventObservation {
        terminal_kind: merge_terminal_kinds(
            stream_terminal_kind,
            anthropic_adapter_terminal_kind(adapter_event.terminal_kind),
        ),
        usage: adapter_event
            .usage()
            .and_then(stream_usage_from_adapter_usage),
    })
}

fn gemini_generate_content_stream_event_observation(
    event: &SseEvent,
) -> Result<StreamEventObservation, StreamChunkError> {
    if event.data.is_empty() {
        return Ok(StreamEventObservation::default());
    }

    let stream_terminal_kind = terminal_event_kind(StreamProtocol::GeminiGenerateContent, event);
    let adapter_event =
        GeminiAdapter::parse_generate_content_stream_event(&event.data).map_err(|error| {
            StreamChunkError::ProtocolParser {
                protocol: GatewayStreamProtocol::GeminiGenerateContent,
                message: error.to_string(),
            }
        })?;

    Ok(StreamEventObservation {
        terminal_kind: merge_terminal_kinds(
            stream_terminal_kind,
            gemini_adapter_terminal_kind(adapter_event.terminal_kind.clone()),
        ),
        usage: adapter_event
            .usage()
            .and_then(stream_usage_from_adapter_usage),
    })
}

const fn responses_adapter_terminal_kind(
    terminal_kind: OpenAiResponsesStreamTerminalKind,
) -> TerminalEventKind {
    match terminal_kind {
        OpenAiResponsesStreamTerminalKind::None => TerminalEventKind::None,
        OpenAiResponsesStreamTerminalKind::Completed => TerminalEventKind::Completed,
        OpenAiResponsesStreamTerminalKind::Failed | OpenAiResponsesStreamTerminalKind::Error => {
            TerminalEventKind::Failed
        }
    }
}

const fn anthropic_adapter_terminal_kind(
    terminal_kind: AnthropicStreamTerminalKind,
) -> TerminalEventKind {
    match terminal_kind {
        AnthropicStreamTerminalKind::None => TerminalEventKind::None,
        AnthropicStreamTerminalKind::MessageStop => TerminalEventKind::Completed,
        AnthropicStreamTerminalKind::Error => TerminalEventKind::Failed,
    }
}

fn gemini_adapter_terminal_kind(terminal_kind: GeminiStreamTerminalKind) -> TerminalEventKind {
    match terminal_kind {
        GeminiStreamTerminalKind::None => TerminalEventKind::None,
        GeminiStreamTerminalKind::FinishReason(_) => TerminalEventKind::Completed,
        GeminiStreamTerminalKind::Error => TerminalEventKind::Failed,
    }
}

const fn merge_terminal_kinds(
    stream_terminal_kind: TerminalEventKind,
    adapter_terminal_kind: TerminalEventKind,
) -> TerminalEventKind {
    match (stream_terminal_kind, adapter_terminal_kind) {
        (TerminalEventKind::Failed, _) | (_, TerminalEventKind::Failed) => {
            TerminalEventKind::Failed
        }
        (TerminalEventKind::Completed, _) | (_, TerminalEventKind::Completed) => {
            TerminalEventKind::Completed
        }
        (TerminalEventKind::None, TerminalEventKind::None) => TerminalEventKind::None,
    }
}

fn stream_usage_from_adapter_usage(usage: AdapterUsage) -> Option<StreamUsageUpdate> {
    let update = StreamUsageUpdate {
        input_tokens: usage.prompt_tokens.and_then(u64_to_i64),
        output_tokens: usage.completion_tokens.and_then(u64_to_i64),
    };

    if update.input_tokens.is_some() || update.output_tokens.is_some() {
        Some(update)
    } else {
        None
    }
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
    metadata: Value,
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
        metadata,
    }
}

const fn rate_limit_reservation_stream_outcome(end_reason: StreamEndReason) -> &'static str {
    match end_reason {
        StreamEndReason::Completed => "completed",
        StreamEndReason::ClientCancel => "client_cancel",
        _ => "stream_error",
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
    use std::{fs, path::PathBuf};

    use super::*;

    fn openai_stream_fixture_path(file_name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("tests")
            .join("fixtures")
            .join("adapters")
            .join("openai")
            .join("streams")
            .join(file_name)
    }

    fn load_openai_stream_fixture(file_name: &str) -> Vec<u8> {
        let path = openai_stream_fixture_path(file_name);
        fs::read(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

    fn anthropic_stream_fixture_path(file_name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("tests")
            .join("fixtures")
            .join("adapters")
            .join("anthropic")
            .join("streams")
            .join(file_name)
    }

    fn load_anthropic_stream_fixture(file_name: &str) -> Vec<u8> {
        let path = anthropic_stream_fixture_path(file_name);
        fs::read(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

    fn gemini_stream_fixture_path(file_name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("tests")
            .join("fixtures")
            .join("adapters")
            .join("gemini")
            .join("streams")
            .join(file_name)
    }

    fn load_gemini_stream_fixture(file_name: &str) -> Vec<u8> {
        let path = gemini_stream_fixture_path(file_name);
        fs::read(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

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
        let attempt = stream_provider_attempt_final_update(
            10,
            StreamEndReason::ClientCancel,
            Some(3),
            json!({}),
        );

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
        let attempt = stream_provider_attempt_final_update(
            10,
            StreamEndReason::ClientCancel,
            None,
            json!({}),
        );

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
        let attempt = stream_provider_attempt_final_update(
            28,
            StreamEndReason::UpstreamError,
            Some(5),
            json!({}),
        );

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
        let mut progress =
            StreamProgress::new(GatewayStreamProtocol::OpenAiChatCompletions, 1024, 1024);

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
    fn responses_stream_progress_tracks_terminal_usage_and_error_terminals() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut completed = StreamProgress::new(GatewayStreamProtocol::OpenAiResponses, 4096, 4096);

        completed
            .observe_chunk(
                &load_openai_stream_fixture("responses_stream_completed.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("completed responses stream should parse");
        assert!(completed.partial_sent);
        assert!(completed.request_ttft_ms.is_some());
        assert_eq!(completed.terminal_kind, TerminalEventKind::None);
        let completed_end = completed
            .observe_eof(request_started_at, provider_started_at)
            .expect("completed responses EOF should classify");
        assert_eq!(completed_end, StreamEndReason::Completed);
        assert_eq!(completed.terminal_kind, TerminalEventKind::Completed);
        assert_eq!(
            completed.usage,
            StreamUsageUpdate {
                input_tokens: Some(3),
                output_tokens: Some(2),
            }
        );
        let completed_update = stream_request_final_update(
            17,
            completed.partial_sent,
            completed_end,
            completed.request_ttft_ms,
            completed.usage,
            Some(StreamRatingUpdate {
                final_cost: "0.00000123".to_string(),
                currency: "USD".to_string(),
                price_version_id: uuid::Uuid::from_u128(61),
            }),
        );
        assert_eq!(completed_update.status, "succeeded");
        assert_eq!(completed_update.input_tokens, Some(3));
        assert_eq!(completed_update.output_tokens, Some(2));
        assert_eq!(completed_update.final_cost.as_deref(), Some("0.00000123"));

        let mut failed = StreamProgress::new(GatewayStreamProtocol::OpenAiResponses, 4096, 4096);
        failed
            .observe_chunk(
                &load_openai_stream_fixture("responses_stream_failed.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("failed responses stream should parse");
        assert!(failed.partial_sent);
        assert_eq!(failed.terminal_kind, TerminalEventKind::None);
        let failed_end = failed
            .observe_eof(request_started_at, provider_started_at)
            .expect("failed responses EOF should classify");
        assert_eq!(failed_end, StreamEndReason::UpstreamError);
        assert_eq!(failed.terminal_kind, TerminalEventKind::Failed);
        let failed_update = stream_request_final_update(
            19,
            failed.partial_sent,
            failed_end,
            failed.request_ttft_ms,
            failed.usage,
            None,
        );
        assert_eq!(failed_update.status, "partial");
        assert_eq!(
            failed_update.error_code.as_deref(),
            Some("stream_upstream_error")
        );
        assert_eq!(failed_update.input_tokens, None);

        let mut error_terminal =
            StreamProgress::new(GatewayStreamProtocol::OpenAiResponses, 4096, 4096);
        error_terminal
            .observe_chunk(
                &load_openai_stream_fixture("responses_stream_error.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("error responses stream should parse through adapter helper");
        assert!(!error_terminal.partial_sent);
        assert_eq!(error_terminal.terminal_kind, TerminalEventKind::None);
        let error_end = error_terminal
            .observe_eof(request_started_at, provider_started_at)
            .expect("error responses EOF should classify");
        assert_eq!(error_end, StreamEndReason::UpstreamError);
        assert_eq!(error_terminal.terminal_kind, TerminalEventKind::Failed);
        let error_update = stream_request_final_update(
            23,
            error_terminal.partial_sent,
            error_end,
            error_terminal.request_ttft_ms,
            error_terminal.usage,
            None,
        );
        assert_eq!(error_update.status, "failed");
        assert_eq!(
            error_update.error_code.as_deref(),
            Some("stream_upstream_error")
        );
    }

    #[test]
    fn responses_stream_progress_keeps_bounds_and_maps_adapter_parse_errors() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let completed_fixture = load_openai_stream_fixture("responses_stream_completed.sse");
        let mut bounded = StreamProgress::new(GatewayStreamProtocol::OpenAiResponses, 4096, 8);

        let too_large = bounded
            .observe_chunk(&completed_fixture, request_started_at, provider_started_at)
            .expect_err("responses stream chunk guard should reject oversized chunks");
        assert_eq!(
            too_large,
            StreamChunkError::ChunkTooLarge {
                len: completed_fixture.len(),
                max: 8,
            }
        );
        assert!(!bounded.partial_sent);

        let mut invalid = StreamProgress::new(GatewayStreamProtocol::OpenAiResponses, 4096, 4096);
        invalid
            .observe_chunk(
                &load_openai_stream_fixture("responses_stream_invalid_json.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("unterminated invalid JSON fixture is buffered until EOF");
        let parse_error = invalid
            .observe_eof(request_started_at, provider_started_at)
            .expect_err("responses adapter parser should reject invalid JSON events");
        match &parse_error {
            StreamChunkError::ProtocolParser { protocol, message } => {
                assert_eq!(*protocol, GatewayStreamProtocol::OpenAiResponses);
                assert!(!message.contains("Authorization"));
                assert!(!message.contains("secret"));
            }
            other => panic!("expected protocol parser error, got {other:?}"),
        }
        assert_eq!(
            stream_forward_failure_contract(StreamForwardFailureKind::from(&parse_error))
                .end_reason,
            StreamEndReason::ParserError
        );
        assert!(!invalid.partial_sent);
        assert_eq!(invalid.terminal_kind, TerminalEventKind::None);
    }

    #[test]
    fn anthropic_stream_progress_tracks_message_stop_and_error_terminals() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut completed =
            StreamProgress::new(GatewayStreamProtocol::AnthropicMessages, 4096, 4096);

        completed
            .observe_chunk(
                &load_anthropic_stream_fixture("messages_stream_completed.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("completed Anthropic stream should parse");
        assert!(completed.partial_sent);
        assert_eq!(completed.terminal_kind, TerminalEventKind::None);
        let completed_end = completed
            .observe_eof(request_started_at, provider_started_at)
            .expect("completed Anthropic EOF should classify");
        assert_eq!(completed_end, StreamEndReason::Completed);
        assert_eq!(completed.terminal_kind, TerminalEventKind::Completed);
        assert_eq!(completed.usage, StreamUsageUpdate::default());

        let mut with_usage =
            StreamProgress::new(GatewayStreamProtocol::AnthropicMessages, 4096, 4096);
        with_usage
            .observe_chunk(
                br#"event: message_delta
data: {"type":"message_delta","usage":{"input_tokens":4,"output_tokens":5}}

event: message_stop
data: {"type":"message_stop"}

"#,
                request_started_at,
                provider_started_at,
            )
            .expect("Anthropic usage event should parse");
        let with_usage_end = with_usage
            .observe_eof(request_started_at, provider_started_at)
            .expect("Anthropic usage EOF should classify");
        assert_eq!(with_usage_end, StreamEndReason::Completed);
        assert_eq!(
            with_usage.usage,
            StreamUsageUpdate {
                input_tokens: Some(4),
                output_tokens: Some(5),
            }
        );
        let usage_update = stream_request_final_update(
            17,
            with_usage.partial_sent,
            with_usage_end,
            with_usage.request_ttft_ms,
            with_usage.usage,
            Some(StreamRatingUpdate {
                final_cost: "0.00000123".to_string(),
                currency: "USD".to_string(),
                price_version_id: uuid::Uuid::from_u128(71),
            }),
        );
        assert_eq!(usage_update.status, "succeeded");
        assert_eq!(usage_update.input_tokens, Some(4));
        assert_eq!(usage_update.output_tokens, Some(5));
        assert_eq!(usage_update.final_cost.as_deref(), Some("0.00000123"));

        let mut error_terminal =
            StreamProgress::new(GatewayStreamProtocol::AnthropicMessages, 4096, 4096);
        error_terminal
            .observe_chunk(
                &load_anthropic_stream_fixture("messages_stream_error.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("error Anthropic stream should parse");
        assert!(!error_terminal.partial_sent);
        assert_eq!(error_terminal.terminal_kind, TerminalEventKind::None);
        let error_end = error_terminal
            .observe_eof(request_started_at, provider_started_at)
            .expect("error Anthropic EOF should classify");
        assert_eq!(error_end, StreamEndReason::UpstreamError);
        assert_eq!(error_terminal.terminal_kind, TerminalEventKind::Failed);
        let error_update = stream_request_final_update(
            19,
            error_terminal.partial_sent,
            error_end,
            error_terminal.request_ttft_ms,
            error_terminal.usage,
            None,
        );
        assert_eq!(error_update.status, "failed");
        assert_eq!(
            error_update.error_code.as_deref(),
            Some("stream_upstream_error")
        );
    }

    #[test]
    fn anthropic_stream_progress_maps_invalid_json_to_parser_error() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut invalid = StreamProgress::new(GatewayStreamProtocol::AnthropicMessages, 4096, 4096);

        invalid
            .observe_chunk(
                &load_anthropic_stream_fixture("messages_stream_invalid_json.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("unterminated invalid JSON fixture is buffered until EOF");
        let parse_error = invalid
            .observe_eof(request_started_at, provider_started_at)
            .expect_err("Anthropic adapter parser should reject invalid JSON events");
        match &parse_error {
            StreamChunkError::ProtocolParser { protocol, message } => {
                assert_eq!(*protocol, GatewayStreamProtocol::AnthropicMessages);
                assert!(!message.contains("Authorization"));
                assert!(!message.contains("x-api-key"));
                assert!(!message.contains("secret"));
            }
            other => panic!("expected protocol parser error, got {other:?}"),
        }
        assert_eq!(
            stream_forward_failure_contract(StreamForwardFailureKind::from(&parse_error))
                .end_reason,
            StreamEndReason::ParserError
        );
        assert!(!invalid.partial_sent);
        assert_eq!(invalid.terminal_kind, TerminalEventKind::None);
    }

    #[test]
    fn gemini_stream_progress_tracks_finish_reason_usage_and_error_terminals() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut completed =
            StreamProgress::new(GatewayStreamProtocol::GeminiGenerateContent, 4096, 4096);

        completed
            .observe_chunk(
                b"data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello\"}]},\"index\":0}]}\n\ndata: {\"candidates\":[{\"index\":0,\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":9,\"candidatesTokenCount\":2,\"totalTokenCount\":11}}\n\n",
                request_started_at,
                provider_started_at,
            )
            .expect("completed Gemini stream should parse");
        assert!(completed.partial_sent);
        assert!(completed.request_ttft_ms.is_some());
        assert_eq!(completed.terminal_kind, TerminalEventKind::Completed);
        assert_eq!(
            completed.usage,
            StreamUsageUpdate {
                input_tokens: Some(9),
                output_tokens: Some(2),
            }
        );
        assert_eq!(
            completed
                .observe_eof(request_started_at, provider_started_at)
                .expect("Gemini completed EOF should classify"),
            StreamEndReason::Completed
        );

        let mut failed =
            StreamProgress::new(GatewayStreamProtocol::GeminiGenerateContent, 4096, 4096);
        failed
            .observe_chunk(
                b"data: {\"error\":{\"code\":500,\"message\":\"provider failed\"}}\n\n",
                request_started_at,
                provider_started_at,
            )
            .expect("Gemini error terminal should parse");
        assert!(!failed.partial_sent);
        assert_eq!(failed.terminal_kind, TerminalEventKind::Failed);
        assert_eq!(
            failed
                .observe_eof(request_started_at, provider_started_at)
                .expect("Gemini error terminal EOF should classify"),
            StreamEndReason::UpstreamError
        );

        let mut invalid =
            StreamProgress::new(GatewayStreamProtocol::GeminiGenerateContent, 4096, 4096);
        invalid
            .observe_chunk(
                &load_gemini_stream_fixture("generate_content_stream_invalid_json.sse"),
                request_started_at,
                provider_started_at,
            )
            .expect("unterminated invalid JSON fixture is buffered until EOF");
        let invalid_error = invalid
            .observe_eof(request_started_at, provider_started_at)
            .expect_err("invalid Gemini stream JSON should be a parser error");
        assert_eq!(
            stream_forward_failure_contract(StreamForwardFailureKind::from(&invalid_error))
                .end_reason,
            StreamEndReason::ParserError
        );
    }

    #[test]
    fn stream_progress_rejects_oversized_chunk_before_mutating_progress() {
        let request_started_at = Instant::now();
        let provider_started_at = Instant::now();
        let mut progress =
            StreamProgress::new(GatewayStreamProtocol::OpenAiChatCompletions, 1024, 8);

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

        let usage = openai_chat_stream_usage_from_event(&event).expect("usage chunk should parse");

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
        let invalid_json = openai_chat_stream_usage_from_event(&SseEvent {
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
