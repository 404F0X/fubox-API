use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelNameCasePolicy {
    #[default]
    Preserve,
    Lower,
    Upper,
}

impl ModelNameCasePolicy {
    pub fn parse(value: impl AsRef<str>) -> Self {
        match value.as_ref().trim().to_ascii_lowercase().as_str() {
            "lower" | "lowercase" => Self::Lower,
            "upper" | "uppercase" => Self::Upper,
            "preserve" | "none" | "" => Self::Preserve,
            _ => Self::Preserve,
        }
    }

    fn apply(self, value: &str) -> String {
        match self {
            Self::Preserve => value.to_owned(),
            Self::Lower => value.to_ascii_lowercase(),
            Self::Upper => value.to_ascii_uppercase(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExplicitModelMapping {
    pub requested_model: String,
    pub upstream_model: String,
}

impl ExplicitModelMapping {
    pub fn new(requested_model: impl Into<String>, upstream_model: impl Into<String>) -> Self {
        Self {
            requested_model: requested_model.into(),
            upstream_model: upstream_model.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ChannelModelMappingPolicy {
    pub explicit_mappings: Vec<ExplicitModelMapping>,
    pub trim_prefixes: Vec<String>,
    pub case_policy: ModelNameCasePolicy,
}

impl ChannelModelMappingPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_explicit_mapping(
        mut self,
        requested_model: impl Into<String>,
        upstream_model: impl Into<String>,
    ) -> Self {
        self.explicit_mappings
            .push(ExplicitModelMapping::new(requested_model, upstream_model));
        self
    }

    pub fn with_trim_prefix(mut self, prefix: impl Into<String>) -> Self {
        self.trim_prefixes.push(prefix.into());
        self
    }

    pub const fn with_case_policy(mut self, case_policy: ModelNameCasePolicy) -> Self {
        self.case_policy = case_policy;
        self
    }
}

pub fn map_upstream_model_name(
    requested_model: impl AsRef<str>,
    policy: &ChannelModelMappingPolicy,
) -> String {
    let requested_model = requested_model.as_ref();

    if let Some(mapping) = policy
        .explicit_mappings
        .iter()
        .find(|mapping| mapping.requested_model == requested_model)
        && !mapping.upstream_model.is_empty()
    {
        return mapping.upstream_model.clone();
    }

    let trimmed = trim_model_prefix(requested_model, &policy.trim_prefixes);
    policy.case_policy.apply(trimmed)
}

fn trim_model_prefix<'a>(model: &'a str, prefixes: &[String]) -> &'a str {
    prefixes
        .iter()
        .filter_map(|prefix| normalized_trim_prefix(model, prefix))
        .max_by_key(|candidate| model.len() - candidate.len())
        .unwrap_or(model)
}

fn normalized_trim_prefix<'a>(model: &'a str, prefix: &str) -> Option<&'a str> {
    let prefix = prefix.trim();
    if prefix.is_empty() {
        return None;
    }

    let prefix_with_separator = if prefix.ends_with('/') {
        prefix.to_owned()
    } else {
        format!("{prefix}/")
    };

    let trimmed = model.strip_prefix(&prefix_with_separator)?;
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_openrouter_style_provider_prefix() {
        let policy = ChannelModelMappingPolicy::new().with_trim_prefix("anthropic");

        let mapped = map_upstream_model_name("anthropic/claude-3.5-sonnet", &policy);

        assert_eq!(mapped, "claude-3.5-sonnet");
    }

    #[test]
    fn trims_prefix_with_or_without_separator() {
        let policy = ChannelModelMappingPolicy::new()
            .with_trim_prefix("openai/")
            .with_trim_prefix("openai");

        assert_eq!(
            map_upstream_model_name("openai/gpt-4o-mini", &policy),
            "gpt-4o-mini"
        );
    }

    #[test]
    fn uses_longest_matching_prefix() {
        let policy = ChannelModelMappingPolicy::new()
            .with_trim_prefix("openrouter")
            .with_trim_prefix("openrouter/meta");

        assert_eq!(
            map_upstream_model_name("openrouter/meta/llama-3.1-70b", &policy),
            "llama-3.1-70b"
        );
    }

    #[test]
    fn applies_lower_case_policy_after_prefix_trim() {
        let policy = ChannelModelMappingPolicy::new()
            .with_trim_prefix("Provider")
            .with_case_policy(ModelNameCasePolicy::Lower);

        assert_eq!(
            map_upstream_model_name("Provider/Claude-3-OPUS", &policy),
            "claude-3-opus"
        );
    }

    #[test]
    fn applies_upper_case_policy_without_prefix_trim() {
        let policy = ChannelModelMappingPolicy::new().with_case_policy(ModelNameCasePolicy::Upper);

        assert_eq!(
            map_upstream_model_name("gpt-4o-mini", &policy),
            "GPT-4O-MINI"
        );
    }

    #[test]
    fn explicit_mapping_takes_priority_over_trim_and_case_policy() {
        let policy = ChannelModelMappingPolicy::new()
            .with_explicit_mapping("openrouter/openai/gpt-4o", "gpt-4o-special")
            .with_trim_prefix("openrouter")
            .with_case_policy(ModelNameCasePolicy::Upper);

        assert_eq!(
            map_upstream_model_name("openrouter/openai/gpt-4o", &policy),
            "gpt-4o-special"
        );
    }

    #[test]
    fn preserves_model_when_no_policy_matches() {
        let policy = ChannelModelMappingPolicy::new().with_trim_prefix("anthropic");

        assert_eq!(
            map_upstream_model_name("openai/gpt-4o-mini", &policy),
            "openai/gpt-4o-mini"
        );
    }

    #[test]
    fn empty_or_invalid_policy_entries_are_stable_preserve_fallbacks() {
        let policy = ChannelModelMappingPolicy::new()
            .with_explicit_mapping("gpt-4o", "")
            .with_trim_prefix("")
            .with_trim_prefix("gpt-4o")
            .with_case_policy(ModelNameCasePolicy::parse("invalid"));

        assert_eq!(map_upstream_model_name("gpt-4o", &policy), "gpt-4o");
    }

    #[test]
    fn parses_case_policy_aliases_and_unknown_values() {
        assert_eq!(
            ModelNameCasePolicy::parse("lowercase"),
            ModelNameCasePolicy::Lower
        );
        assert_eq!(
            ModelNameCasePolicy::parse("UPPER"),
            ModelNameCasePolicy::Upper
        );
        assert_eq!(
            ModelNameCasePolicy::parse("unexpected"),
            ModelNameCasePolicy::Preserve
        );
    }
}
