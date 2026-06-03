use bytes::Bytes;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamEndReason {
    Completed,
    ClientCancel,
    UpstreamEof,
    UpstreamError,
    ParserError,
    Timeout,
    GatewayAbort,
}

impl StreamEndReason {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::ClientCancel => "client_cancel",
            Self::UpstreamEof => "upstream_eof",
            Self::UpstreamError => "upstream_error",
            Self::ParserError => "parser_error",
            Self::Timeout => "timeout",
            Self::GatewayAbort => "gateway_abort",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamProtocol {
    OpenAiChatCompletions,
    OpenAiResponses,
    AnthropicMessages,
    GeminiGenerateContent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalEventKind {
    None,
    Completed,
    Failed,
}

impl TerminalEventKind {
    pub const fn is_terminal(self) -> bool {
        !matches!(self, Self::None)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamEndSignal {
    TerminalEvent,
    UpstreamEof,
    UpstreamError,
    ParserError,
    ClientCancel,
    Timeout,
    GatewayAbort,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    pub event: Option<String>,
    pub data: Bytes,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SseParseError {
    #[error("sse event exceeds max size")]
    EventTooLarge,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SseDecodeError {
    #[error(transparent)]
    Parse(#[from] SseParseError),
    #[error("sse buffer exceeds max size before an event boundary")]
    BufferTooLarge,
}

#[derive(Debug, Clone)]
pub struct SseParser {
    max_event_bytes: usize,
}

impl SseParser {
    pub fn new(max_event_bytes: usize) -> Self {
        Self { max_event_bytes }
    }

    pub fn parse_block(&self, block: &[u8]) -> Result<SseEvent, SseParseError> {
        if block.len() > self.max_event_bytes {
            return Err(SseParseError::EventTooLarge);
        }

        let mut event = None;
        let mut data = Vec::new();

        for line in block.split(|b| *b == b'\n') {
            let line = trim_cr(line);
            if let Some(value) = line.strip_prefix(b"event:") {
                event = Some(String::from_utf8_lossy(value).trim().to_string());
            } else if let Some(value) = line.strip_prefix(b"data:") {
                if !data.is_empty() {
                    data.push(b'\n');
                }
                data.extend_from_slice(trim_one_leading_space(value));
            }
        }

        Ok(SseEvent {
            event,
            data: Bytes::from(data),
        })
    }
}

#[derive(Debug, Clone)]
pub struct SseDecoder {
    parser: SseParser,
    buffer: Vec<u8>,
}

impl SseDecoder {
    pub fn new(max_event_bytes: usize) -> Self {
        Self {
            parser: SseParser::new(max_event_bytes),
            buffer: Vec::new(),
        }
    }

    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<SseEvent>, SseDecodeError> {
        self.buffer.extend_from_slice(chunk);
        if self.buffer.len() > self.parser.max_event_bytes
            && find_sse_boundary(&self.buffer).is_none()
        {
            return Err(SseDecodeError::BufferTooLarge);
        }

        let mut events = Vec::new();
        while let Some((boundary, boundary_len)) = find_sse_boundary(&self.buffer) {
            let block = self.buffer[..boundary].to_vec();
            self.buffer.drain(..boundary + boundary_len);

            if trim_ascii(&block).is_empty() {
                continue;
            }

            events.push(self.parser.parse_block(&block)?);
        }

        Ok(events)
    }

    pub fn finish(&mut self) -> Result<Vec<SseEvent>, SseDecodeError> {
        if trim_ascii(&self.buffer).is_empty() {
            self.buffer.clear();
            return Ok(Vec::new());
        }

        if self.buffer.len() > self.parser.max_event_bytes {
            return Err(SseDecodeError::BufferTooLarge);
        }

        let block = std::mem::take(&mut self.buffer);
        Ok(vec![self.parser.parse_block(&block)?])
    }
}

fn find_sse_boundary(buffer: &[u8]) -> Option<(usize, usize)> {
    let lf = buffer
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|index| (index, 2));
    let crlf = buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| (index, 4));

    match (lf, crlf) {
        (Some(lf), Some(crlf)) => Some(if lf.0 <= crlf.0 { lf } else { crlf }),
        (Some(lf), None) => Some(lf),
        (None, Some(crlf)) => Some(crlf),
        (None, None) => None,
    }
}

pub fn terminal_event_kind(protocol: StreamProtocol, event: &SseEvent) -> TerminalEventKind {
    match protocol {
        StreamProtocol::OpenAiChatCompletions => {
            if trim_ascii(&event.data) == b"[DONE]" {
                TerminalEventKind::Completed
            } else {
                TerminalEventKind::None
            }
        }
        StreamProtocol::OpenAiResponses => responses_terminal_event_kind(event),
        StreamProtocol::AnthropicMessages => anthropic_terminal_event_kind(event),
        StreamProtocol::GeminiGenerateContent => {
            if json_key_has_non_null_value(&event.data, b"finishReason")
                || json_key_has_non_null_value(&event.data, b"finish_reason")
            {
                TerminalEventKind::Completed
            } else {
                TerminalEventKind::None
            }
        }
    }
}

pub fn is_terminal_event(protocol: StreamProtocol, event: &SseEvent) -> bool {
    terminal_event_kind(protocol, event).is_terminal()
}

pub const fn stream_end_reason(terminal_seen: bool, signal: StreamEndSignal) -> StreamEndReason {
    match signal {
        StreamEndSignal::TerminalEvent => StreamEndReason::Completed,
        StreamEndSignal::UpstreamEof if terminal_seen => StreamEndReason::Completed,
        StreamEndSignal::UpstreamEof => StreamEndReason::UpstreamEof,
        StreamEndSignal::UpstreamError => StreamEndReason::UpstreamError,
        StreamEndSignal::ParserError => StreamEndReason::ParserError,
        StreamEndSignal::ClientCancel => StreamEndReason::ClientCancel,
        StreamEndSignal::Timeout => StreamEndReason::Timeout,
        StreamEndSignal::GatewayAbort => StreamEndReason::GatewayAbort,
    }
}

pub const fn determine_stream_end_reason(
    terminal_seen: bool,
    signal: StreamEndSignal,
) -> StreamEndReason {
    stream_end_reason(terminal_seen, signal)
}

pub const fn stream_end_reason_for_terminal_kind(
    terminal_kind: TerminalEventKind,
    signal: StreamEndSignal,
) -> StreamEndReason {
    match signal {
        StreamEndSignal::TerminalEvent => match terminal_kind {
            TerminalEventKind::Failed => StreamEndReason::UpstreamError,
            TerminalEventKind::Completed => StreamEndReason::Completed,
            TerminalEventKind::None => StreamEndReason::UpstreamEof,
        },
        StreamEndSignal::UpstreamEof if matches!(terminal_kind, TerminalEventKind::Failed) => {
            StreamEndReason::UpstreamError
        }
        StreamEndSignal::UpstreamEof => {
            stream_end_reason(terminal_kind.is_terminal(), StreamEndSignal::UpstreamEof)
        }
        _ => stream_end_reason(terminal_kind.is_terminal(), signal),
    }
}

fn responses_terminal_event_kind(event: &SseEvent) -> TerminalEventKind {
    match event.event.as_deref() {
        Some("response.completed") => TerminalEventKind::Completed,
        Some("response.failed" | "response.incomplete" | "response.cancelled") => {
            TerminalEventKind::Failed
        }
        _ if json_key_string_value_eq(&event.data, b"type", b"response.completed") => {
            TerminalEventKind::Completed
        }
        _ if json_key_string_value_eq(&event.data, b"type", b"response.failed")
            || json_key_string_value_eq(&event.data, b"type", b"response.incomplete")
            || json_key_string_value_eq(&event.data, b"type", b"response.cancelled") =>
        {
            TerminalEventKind::Failed
        }
        _ => TerminalEventKind::None,
    }
}

fn anthropic_terminal_event_kind(event: &SseEvent) -> TerminalEventKind {
    match event.event.as_deref() {
        Some("message_stop") => TerminalEventKind::Completed,
        Some("error") => TerminalEventKind::Failed,
        _ if json_key_string_value_eq(&event.data, b"type", b"message_stop") => {
            TerminalEventKind::Completed
        }
        _ if json_key_string_value_eq(&event.data, b"type", b"error") => TerminalEventKind::Failed,
        _ => TerminalEventKind::None,
    }
}

fn trim_cr(line: &[u8]) -> &[u8] {
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn trim_one_leading_space(line: &[u8]) -> &[u8] {
    line.strip_prefix(b" ").unwrap_or(line)
}

fn trim_ascii(value: &[u8]) -> &[u8] {
    let mut start = 0;
    let mut end = value.len();

    while start < end && value[start].is_ascii_whitespace() {
        start += 1;
    }

    while end > start && value[end - 1].is_ascii_whitespace() {
        end -= 1;
    }

    &value[start..end]
}

fn json_key_string_value_eq(input: &[u8], key: &[u8], value: &[u8]) -> bool {
    let mut index = 0;

    while index < input.len() {
        if input[index] != b'"' {
            index += 1;
            continue;
        }

        let Some((key_matches, string_end)) = json_string_matches(input, index, key) else {
            return false;
        };

        index = string_end;
        if !key_matches {
            continue;
        }

        let colon = skip_json_ws(input, string_end);
        if input.get(colon) != Some(&b':') {
            continue;
        }

        let value_start = skip_json_ws(input, colon + 1);
        if input.get(value_start) != Some(&b'"') {
            continue;
        }

        let Some((value_matches, _)) = json_string_matches(input, value_start, value) else {
            return false;
        };
        if value_matches {
            return true;
        }
    }

    false
}

fn json_key_has_non_null_value(input: &[u8], key: &[u8]) -> bool {
    let mut index = 0;

    while index < input.len() {
        if input[index] != b'"' {
            index += 1;
            continue;
        }

        let Some((key_matches, string_end)) = json_string_matches(input, index, key) else {
            return false;
        };

        index = string_end;
        if !key_matches {
            continue;
        }

        let colon = skip_json_ws(input, string_end);
        if input.get(colon) != Some(&b':') {
            continue;
        }

        return json_value_is_non_null(input, skip_json_ws(input, colon + 1));
    }

    false
}

fn json_string_matches(input: &[u8], start: usize, expected: &[u8]) -> Option<(bool, usize)> {
    if input.get(start) != Some(&b'"') {
        return None;
    }

    let mut index = start + 1;
    let mut expected_index = 0;
    let mut matches = true;

    while index < input.len() {
        match input[index] {
            b'\\' => {
                matches = false;
                index += 1;
                if index >= input.len() {
                    return None;
                }
                index += 1;
            }
            b'"' => {
                return Some((matches && expected_index == expected.len(), index + 1));
            }
            byte => {
                if expected.get(expected_index) != Some(&byte) {
                    matches = false;
                }
                expected_index += 1;
                index += 1;
            }
        }
    }

    None
}

fn skip_json_ws(input: &[u8], mut index: usize) -> usize {
    while index < input.len() && input[index].is_ascii_whitespace() {
        index += 1;
    }
    index
}

fn json_value_is_non_null(input: &[u8], index: usize) -> bool {
    match input.get(index) {
        Some(b'"') => json_string_is_closed(input, index),
        Some(b'{' | b'[' | b't' | b'f' | b'-' | b'0'..=b'9') => true,
        _ => false,
    }
}

fn json_string_is_closed(input: &[u8], start: usize) -> bool {
    if input.get(start) != Some(&b'"') {
        return false;
    }

    let mut index = start + 1;
    while index < input.len() {
        match input[index] {
            b'\\' => index += 2,
            b'"' => return true,
            _ => index += 1,
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use super::*;

    fn adapter_stream_fixture_path(adapter: &str, file_name: &str) -> PathBuf {
        let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.pop();
        path.pop();
        path.push("tests");
        path.push("fixtures");
        path.push("adapters");
        path.push(adapter);
        path.push("streams");
        path.push(file_name);
        path
    }

    fn load_adapter_stream_fixture(adapter: &str, file_name: &str) -> String {
        let path = adapter_stream_fixture_path(adapter, file_name);
        fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
    }

    fn stream_fixture_blocks(adapter: &str, file_name: &str) -> Vec<String> {
        load_adapter_stream_fixture(adapter, file_name)
            .replace("\r\n", "\n")
            .split("\n\n")
            .filter(|block| !block.trim().is_empty())
            .map(str::to_string)
            .collect()
    }

    fn openai_stream_fixture_blocks(file_name: &str) -> Vec<String> {
        stream_fixture_blocks("openai", file_name)
    }

    fn parse_adapter_stream_fixture(
        adapter: &str,
        file_name: &str,
        max_event_bytes: usize,
    ) -> Vec<SseEvent> {
        let parser = SseParser::new(max_event_bytes);
        stream_fixture_blocks(adapter, file_name)
            .into_iter()
            .map(|block| {
                parser
                    .parse_block(block.as_bytes())
                    .unwrap_or_else(|error| {
                        panic!("failed to parse SSE block in {adapter}/{file_name}: {error}")
                    })
            })
            .collect()
    }

    fn parse_openai_stream_fixture(file_name: &str, max_event_bytes: usize) -> Vec<SseEvent> {
        parse_adapter_stream_fixture("openai", file_name, max_event_bytes)
    }

    fn decode_adapter_stream_fixture(
        adapter: &str,
        file_name: &str,
        chunk_size: usize,
    ) -> Vec<SseEvent> {
        let mut decoder = SseDecoder::new(4096);
        let mut events = Vec::new();
        let fixture = load_adapter_stream_fixture(adapter, file_name);

        for chunk in fixture.as_bytes().chunks(chunk_size) {
            events.extend(decoder.push(chunk).expect("fixture chunk should decode"));
        }
        events.extend(decoder.finish().expect("fixture EOF should decode"));

        events
    }

    fn decode_openai_stream_fixture(file_name: &str, chunk_size: usize) -> Vec<SseEvent> {
        decode_adapter_stream_fixture("openai", file_name, chunk_size)
    }

    fn terminal_kind_for_events(
        protocol: StreamProtocol,
        events: &[SseEvent],
    ) -> TerminalEventKind {
        events
            .iter()
            .map(|event| terminal_event_kind(protocol, event))
            .find(|kind| kind.is_terminal())
            .unwrap_or(TerminalEventKind::None)
    }

    #[test]
    fn parses_large_event_without_scanner_limit() {
        let parser = SseParser::new(4 * 1024 * 1024);
        let payload = "x".repeat(70 * 1024);
        let block = format!("event: message\ndata: {payload}\n");
        let event = parser.parse_block(block.as_bytes()).unwrap();
        assert_eq!(event.event.as_deref(), Some("message"));
        assert_eq!(event.data.len(), payload.len());
    }

    #[test]
    fn rejects_oversized_event() {
        let parser = SseParser::new(8);
        let err = parser.parse_block(b"data: too-large\n").unwrap_err();
        assert_eq!(err, SseParseError::EventTooLarge);
    }

    #[test]
    fn decoder_rejects_unbounded_buffer_without_event_boundary() {
        let mut decoder = SseDecoder::new(8);
        let err = decoder
            .push(b"data: no-boundary")
            .expect_err("decoder should cap buffered bytes before an event boundary");

        assert_eq!(err, SseDecodeError::BufferTooLarge);
    }

    #[test]
    fn validates_openai_done_terminal_event() {
        let parser = SseParser::new(1024);
        let event = parser.parse_block(b"data:  [DONE]\r\n").unwrap();

        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiChatCompletions, &event),
            TerminalEventKind::Completed
        );
        assert!(is_terminal_event(
            StreamProtocol::OpenAiChatCompletions,
            &event
        ));
    }

    #[test]
    fn validates_openai_chat_stream_fixture_ending_done() {
        let events = parse_openai_stream_fixture("chat_stream_valid_done.sse", 4096);

        assert_eq!(events.len(), 4);
        for event in &events[..3] {
            assert_eq!(
                terminal_event_kind(StreamProtocol::OpenAiChatCompletions, event),
                TerminalEventKind::None
            );
            assert!(event.data.as_ref().starts_with(b"{"));
        }

        let done = events.last().expect("DONE event");
        assert_eq!(done.data.as_ref(), b"[DONE]");
        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiChatCompletions, done),
            TerminalEventKind::Completed
        );
        assert_eq!(
            stream_end_reason_for_terminal_kind(
                TerminalEventKind::Completed,
                StreamEndSignal::TerminalEvent
            ),
            StreamEndReason::Completed
        );
        assert_eq!(
            stream_end_reason(true, StreamEndSignal::UpstreamEof),
            StreamEndReason::Completed
        );
    }

    #[test]
    fn decodes_split_openai_chat_stream_and_detects_done() {
        let events = decode_openai_stream_fixture("chat_stream_valid_done.sse", 7);
        let terminal_seen = events
            .iter()
            .any(|event| is_terminal_event(StreamProtocol::OpenAiChatCompletions, event));

        assert_eq!(events.len(), 4);
        assert!(terminal_seen);
        assert_eq!(
            stream_end_reason(terminal_seen, StreamEndSignal::UpstreamEof),
            StreamEndReason::Completed
        );
    }

    #[test]
    fn treats_invalid_openai_stream_json_fixture_as_non_terminal_parser_anomaly() {
        let events = parse_openai_stream_fixture("chat_stream_invalid_json.sse", 4096);

        assert_eq!(events.len(), 1);
        let malformed = events[0].data.as_ref();
        assert!(malformed.starts_with(b"{"));
        assert!(
            std::str::from_utf8(malformed)
                .expect("fixture should be utf8")
                .contains("\"unterminated}")
        );
        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiChatCompletions, &events[0]),
            TerminalEventKind::None
        );
        assert_eq!(
            stream_end_reason(false, StreamEndSignal::ParserError),
            StreamEndReason::ParserError
        );
    }

    #[test]
    fn validates_large_openai_stream_fixture_and_size_limit() {
        let events = parse_openai_stream_fixture("chat_stream_large_chunk.sse", 4096);

        assert_eq!(events.len(), 2);
        assert!(events[0].data.len() > 512);
        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiChatCompletions, &events[0]),
            TerminalEventKind::None
        );
        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiChatCompletions, &events[1]),
            TerminalEventKind::Completed
        );

        let blocks = openai_stream_fixture_blocks("chat_stream_large_chunk.sse");
        let error = SseParser::new(512)
            .parse_block(blocks[0].as_bytes())
            .expect_err("large fixture should exceed a small parser limit");
        assert_eq!(error, SseParseError::EventTooLarge);
        assert_eq!(
            stream_end_reason(false, StreamEndSignal::ParserError),
            StreamEndReason::ParserError
        );
    }

    #[test]
    fn missing_openai_done_fixture_maps_upstream_eof_to_incomplete_end() {
        let events = parse_openai_stream_fixture("chat_stream_missing_done.sse", 4096);
        let terminal_seen = events
            .iter()
            .any(|event| is_terminal_event(StreamProtocol::OpenAiChatCompletions, event));

        assert_eq!(events.len(), 3);
        assert!(!terminal_seen);
        assert_eq!(
            stream_end_reason(terminal_seen, StreamEndSignal::UpstreamEof),
            StreamEndReason::UpstreamEof
        );
        assert_eq!(
            stream_end_reason_for_terminal_kind(
                TerminalEventKind::None,
                StreamEndSignal::UpstreamEof
            ),
            StreamEndReason::UpstreamEof
        );
    }

    #[test]
    fn decoder_missing_done_maps_eof_to_upstream_eof() {
        let events = decode_openai_stream_fixture("chat_stream_missing_done.sse", 11);
        let terminal_seen = events
            .iter()
            .any(|event| is_terminal_event(StreamProtocol::OpenAiChatCompletions, event));

        assert_eq!(events.len(), 3);
        assert!(!terminal_seen);
        assert_eq!(
            stream_end_reason(terminal_seen, StreamEndSignal::UpstreamEof),
            StreamEndReason::UpstreamEof
        );
    }

    #[test]
    fn validates_responses_terminal_events() {
        let parser = SseParser::new(1024);
        let event = parser
            .parse_block(b"event: response.completed\ndata: {\"type\":\"response.completed\"}\n")
            .unwrap();
        let failed = parser
            .parse_block(b"data: {\"type\":\"response.failed\"}\n")
            .unwrap();

        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiResponses, &event),
            TerminalEventKind::Completed
        );
        assert_eq!(
            terminal_event_kind(StreamProtocol::OpenAiResponses, &failed),
            TerminalEventKind::Failed
        );
    }

    #[test]
    fn validates_anthropic_terminal_events() {
        let parser = SseParser::new(1024);
        let event = parser
            .parse_block(b"event: message_stop\ndata: {\"type\":\"message_stop\"}\n")
            .unwrap();

        assert_eq!(
            terminal_event_kind(StreamProtocol::AnthropicMessages, &event),
            TerminalEventKind::Completed
        );
    }

    #[test]
    fn validates_gemini_terminal_candidates_without_json_buffer() {
        let parser = SseParser::new(1024);
        let terminal = parser
            .parse_block(b"data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n")
            .unwrap();
        let non_terminal = parser
            .parse_block(
                b"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"finishReason\"}]}}]}\n",
            )
            .unwrap();
        let escaped_text = parser
            .parse_block(
                b"data: {\"text\":\"{\\\"finishReason\\\":\\\"STOP\\\"}\",\"finishReason\":null}\n",
            )
            .unwrap();

        assert_eq!(
            terminal_event_kind(StreamProtocol::GeminiGenerateContent, &terminal),
            TerminalEventKind::Completed
        );
        assert_eq!(
            terminal_event_kind(StreamProtocol::GeminiGenerateContent, &non_terminal),
            TerminalEventKind::None
        );
        assert_eq!(
            terminal_event_kind(StreamProtocol::GeminiGenerateContent, &escaped_text),
            TerminalEventKind::None
        );
    }

    #[test]
    fn cross_protocol_terminal_fixtures_map_eof_end_reasons() {
        for (
            protocol,
            adapter,
            fixture_name,
            expected_event_count,
            expected_terminal_kind,
            expected_end_reason,
        ) in [
            (
                StreamProtocol::OpenAiResponses,
                "openai",
                "responses_stream_completed.sse",
                3,
                TerminalEventKind::Completed,
                StreamEndReason::Completed,
            ),
            (
                StreamProtocol::OpenAiResponses,
                "openai",
                "responses_stream_failed.sse",
                2,
                TerminalEventKind::Failed,
                StreamEndReason::UpstreamError,
            ),
            (
                StreamProtocol::OpenAiResponses,
                "openai",
                "responses_stream_missing_terminal.sse",
                3,
                TerminalEventKind::None,
                StreamEndReason::UpstreamEof,
            ),
            (
                StreamProtocol::AnthropicMessages,
                "anthropic",
                "messages_stream_completed.sse",
                3,
                TerminalEventKind::Completed,
                StreamEndReason::Completed,
            ),
            (
                StreamProtocol::AnthropicMessages,
                "anthropic",
                "messages_stream_error.sse",
                1,
                TerminalEventKind::Failed,
                StreamEndReason::UpstreamError,
            ),
            (
                StreamProtocol::AnthropicMessages,
                "anthropic",
                "messages_stream_missing_terminal.sse",
                3,
                TerminalEventKind::None,
                StreamEndReason::UpstreamEof,
            ),
            (
                StreamProtocol::GeminiGenerateContent,
                "gemini",
                "generate_content_stream_completed.sse",
                1,
                TerminalEventKind::Completed,
                StreamEndReason::Completed,
            ),
            (
                StreamProtocol::GeminiGenerateContent,
                "gemini",
                "generate_content_stream_missing_terminal.sse",
                1,
                TerminalEventKind::None,
                StreamEndReason::UpstreamEof,
            ),
        ] {
            let events = parse_adapter_stream_fixture(adapter, fixture_name, 4096);
            let label = format!("{adapter}/{fixture_name}");
            let terminal_kind = terminal_kind_for_events(protocol, &events);

            assert_eq!(events.len(), expected_event_count, "{label}");
            assert_eq!(terminal_kind, expected_terminal_kind, "{label}");
            assert_eq!(
                stream_end_reason_for_terminal_kind(terminal_kind, StreamEndSignal::UpstreamEof),
                expected_end_reason,
                "{label}"
            );

            if terminal_kind.is_terminal() {
                assert_eq!(
                    stream_end_reason_for_terminal_kind(
                        terminal_kind,
                        StreamEndSignal::TerminalEvent
                    ),
                    expected_end_reason,
                    "{label}"
                );
            }
        }
    }

    #[test]
    fn decodes_split_cross_protocol_terminal_fixtures() {
        for (protocol, adapter, fixture_name, expected_terminal_kind) in [
            (
                StreamProtocol::OpenAiResponses,
                "openai",
                "responses_stream_completed.sse",
                TerminalEventKind::Completed,
            ),
            (
                StreamProtocol::OpenAiResponses,
                "openai",
                "responses_stream_missing_terminal.sse",
                TerminalEventKind::None,
            ),
            (
                StreamProtocol::AnthropicMessages,
                "anthropic",
                "messages_stream_completed.sse",
                TerminalEventKind::Completed,
            ),
            (
                StreamProtocol::AnthropicMessages,
                "anthropic",
                "messages_stream_missing_terminal.sse",
                TerminalEventKind::None,
            ),
            (
                StreamProtocol::GeminiGenerateContent,
                "gemini",
                "generate_content_stream_completed.sse",
                TerminalEventKind::Completed,
            ),
            (
                StreamProtocol::GeminiGenerateContent,
                "gemini",
                "generate_content_stream_missing_terminal.sse",
                TerminalEventKind::None,
            ),
        ] {
            let events = decode_adapter_stream_fixture(adapter, fixture_name, 13);

            assert_eq!(
                terminal_kind_for_events(protocol, &events),
                expected_terminal_kind,
                "{adapter}/{fixture_name}"
            );
        }
    }

    #[test]
    fn invalid_json_stream_fixtures_remain_non_terminal_and_map_parser_error() {
        assert_eq!(
            stream_end_reason(true, StreamEndSignal::ParserError),
            StreamEndReason::ParserError
        );

        for (protocol, adapter, fixture_name) in [
            (
                StreamProtocol::OpenAiResponses,
                "openai",
                "responses_stream_invalid_json.sse",
            ),
            (
                StreamProtocol::AnthropicMessages,
                "anthropic",
                "messages_stream_invalid_json.sse",
            ),
            (
                StreamProtocol::GeminiGenerateContent,
                "gemini",
                "generate_content_stream_invalid_json.sse",
            ),
        ] {
            let events = parse_adapter_stream_fixture(adapter, fixture_name, 4096);
            let terminal_kind = terminal_kind_for_events(protocol, &events);
            let malformed = events
                .first()
                .unwrap_or_else(|| panic!("{adapter}/{fixture_name} should contain an event"))
                .data
                .as_ref();

            assert_eq!(events.len(), 1, "{adapter}/{fixture_name}");
            assert!(
                std::str::from_utf8(malformed)
                    .expect("fixture should be utf8")
                    .contains("unterminated"),
                "{adapter}/{fixture_name}"
            );
            assert_eq!(
                terminal_kind,
                TerminalEventKind::None,
                "{adapter}/{fixture_name}"
            );
            assert_eq!(
                stream_end_reason_for_terminal_kind(terminal_kind, StreamEndSignal::ParserError),
                StreamEndReason::ParserError,
                "{adapter}/{fixture_name}"
            );
        }
    }

    #[test]
    fn determines_stream_end_reason_from_terminal_and_signal() {
        assert_eq!(
            stream_end_reason(false, StreamEndSignal::UpstreamEof),
            StreamEndReason::UpstreamEof
        );
        assert_eq!(
            stream_end_reason(true, StreamEndSignal::UpstreamEof),
            StreamEndReason::Completed
        );
        assert_eq!(
            stream_end_reason(false, StreamEndSignal::ClientCancel),
            StreamEndReason::ClientCancel
        );
        assert_eq!(
            stream_end_reason(true, StreamEndSignal::ClientCancel),
            StreamEndReason::ClientCancel
        );
        assert_eq!(
            stream_end_reason_for_terminal_kind(
                TerminalEventKind::Completed,
                StreamEndSignal::ClientCancel
            ),
            StreamEndReason::ClientCancel
        );
        assert_eq!(
            stream_end_reason(true, StreamEndSignal::ParserError),
            StreamEndReason::ParserError
        );
        assert_eq!(
            stream_end_reason(false, StreamEndSignal::Timeout),
            StreamEndReason::Timeout
        );
        assert_eq!(
            stream_end_reason(true, StreamEndSignal::GatewayAbort),
            StreamEndReason::GatewayAbort
        );
    }

    #[test]
    fn failed_terminal_maps_to_upstream_error_when_stream_closes() {
        assert_eq!(
            stream_end_reason_for_terminal_kind(
                TerminalEventKind::Failed,
                StreamEndSignal::UpstreamEof
            ),
            StreamEndReason::UpstreamError
        );
    }
}
