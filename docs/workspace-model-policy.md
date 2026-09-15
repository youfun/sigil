# Project-Level Model Access Policy Examples

This directory contains example `.sigil/models.json` files that can be placed
in a workspace root to restrict which models are available for that project.

## Format

```json
{
  "version": 1,
  "default": {
    "provider": "<provider-id>",
    "model": "<model-id>"
  },
  "allow": {
    "providers": {
      "<provider-id>": {
        "models": ["<model-id>", ...]
      }
    }
  }
}
```

The `provider-id` and `model-id` values must match those defined in the
global `~/.sigil/models.json` configuration.

## Examples

### Sensitive project — local models only

```json
{
  "version": 1,
  "default": {
    "provider": "local-llm",
    "model": "qwen2.5-coder:7b"
  },
  "allow": {
    "providers": {
      "local-llm": {
        "models": [
          "qwen2.5-coder:7b"
        ]
      }
    }
  }
}
```

### Mixed project — cloud + local

```json
{
  "version": 1,
  "default": {
    "provider": "stepfun-anthropic",
    "model": "step-router-v1"
  },
  "allow": {
    "providers": {
      "stepfun-anthropic": {
        "models": [
          "step-router-v1"
        ]
      },
      "local-llm": {
        "models": [
          "qwen2.5-coder:7b",
          "deepseek-coder:6.7b"
        ]
      }
    }
  }
}
```

### Locked project — no models allowed

```json
{
  "version": 1,
  "allow": {
    "providers": {}
  }
}
```

## Behavior

- **No `.sigil/models.json`**: All global models available (unrestricted).
- **Valid policy file**: Strict allowlist mode — only listed provider/model
  pairs are available. No fallback to global models.
- **Malformed policy file**: No models available. The project is effectively
  locked until the policy file is fixed.
- **Policy default not in allowlist**: Auto-selects the first allowed model.
- **Policy references non-existent provider/model**: Ignored (no crash).
