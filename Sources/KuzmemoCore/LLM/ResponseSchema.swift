import Foundation

/// The JSON Schema passed to `claude -p --json-schema`. Source of truth for the response contract. Only `intent` and
/// `confidence` are required, so the model can omit empty fields and keep the output (and the latency) short.
public enum ResponseSchema {
    public static let json: String = #"""
{
 "$schema": "http://json-schema.org/draft-07/schema#",
 "type": "object",
 "additionalProperties": false,
 "required": [
  "intent",
  "confidence"
 ],
 "properties": {
  "intent": {
   "enum": [
    "create",
    "query",
    "update",
    "delete",
    "clarify",
    "unknown"
   ]
  },
  "confidence": {
   "type": "number"
  },
  "transcript_corrected": {
   "type": "string"
  },
  "actions": {
   "type": "array",
   "maxItems": 8,
   "items": {
    "$ref": "#/definitions/action"
   }
  },
  "query": {
   "$ref": "#/definitions/query"
  },
  "clarification": {
   "$ref": "#/definitions/clarification"
  },
  "speech": {
   "type": "string",
   "description": "In Russian address the user as \"ты\" (never \"вы\")."
  }
 },
 "definitions": {
  "weekday": {
   "enum": [
    "mon",
    "tue",
    "wed",
    "thu",
    "fri",
    "sat",
    "sun"
   ]
  },
  "when": {
   "type": "object",
   "additionalProperties": false,
   "required": [
    "mode"
   ],
   "properties": {
    "mode": {
     "enum": [
      "none",
      "absolute",
      "days_from_today",
      "weekday",
      "minutes_from_now",
      "month_part"
     ]
    },
    "phrase": {
     "type": "string"
    },
    "date": {
     "type": "string"
    },
    "days_from_today": {
     "type": "integer"
    },
    "weekday": {
     "$ref": "#/definitions/weekday"
    },
    "week_offset": {
     "type": "integer"
    },
    "minutes_from_now": {
     "type": "integer"
    },
    "month_part": {
     "enum": [
      "start",
      "end"
     ]
    },
    "month_offset": {
     "type": "integer"
    },
    "time": {
     "type": "string"
    },
    "day_part": {
     "enum": [
      "morning",
      "day",
      "evening",
      "night"
     ]
    },
    "approximate": {
     "type": "boolean"
    }
   }
  },
  "recurrence": {
   "type": "object",
   "additionalProperties": false,
   "required": [
    "freq"
   ],
   "properties": {
    "freq": {
     "enum": [
      "daily",
      "weekly",
      "monthly",
      "yearly"
     ]
    },
    "interval": {
     "type": "integer"
    },
    "by_weekday": {
     "type": "array",
     "items": {
      "$ref": "#/definitions/weekday"
     }
    },
    "by_monthday": {
     "type": "integer"
    },
    "until": {
     "type": "string"
    },
    "count": {
     "type": "integer"
    }
   }
  },
  "item": {
   "type": "object",
   "additionalProperties": false,
   "required": [
    "kind",
    "title"
   ],
   "properties": {
    "kind": {
     "enum": [
      "reminder",
      "event",
      "task",
      "note"
     ]
    },
    "title": {
     "type": "string"
    },
    "details": {
     "type": "string"
    },
    "when": {
     "$ref": "#/definitions/when"
    },
    "duration_min": {
     "type": "integer"
    },
    "recurrence": {
     "$ref": "#/definitions/recurrence"
    },
    "keywords": {
     "type": "array",
     "maxItems": 6,
     "items": {
      "type": "string"
     }
    }
   }
  },
  "changes": {
   "type": "object",
   "additionalProperties": false,
   "properties": {
    "kind": {
     "enum": [
      "reminder",
      "event",
      "task",
      "note"
     ]
    },
    "title": {
     "type": "string"
    },
    "details": {
     "type": "string"
    },
    "when": {
     "$ref": "#/definitions/when"
    },
    "duration_min": {
     "type": "integer"
    },
    "recurrence": {
     "$ref": "#/definitions/recurrence"
    },
    "keywords": {
     "type": "array",
     "maxItems": 6,
     "items": {
      "type": "string"
     }
    },
    "clear": {
     "type": "array",
     "uniqueItems": true,
     "maxItems": 6,
     "items": {
      "enum": [
       "date",
       "time",
       "details",
       "duration_min",
       "recurrence",
       "keywords"
      ]
     }
    }
   }
  },
  "action": {
   "type": "object",
   "additionalProperties": false,
   "required": [
    "op"
   ],
   "properties": {
    "op": {
     "enum": [
      "create",
      "update",
      "complete",
      "reopen",
      "delete",
      "skip_occurrence"
     ]
    },
    "ref": {
     "type": "integer"
    },
    "target_hint": {
     "type": "string"
    },
    "occurrence_date": {
     "type": "string"
    },
    "item": {
     "$ref": "#/definitions/item"
    },
    "changes": {
     "$ref": "#/definitions/changes"
    }
   }
  },
  "query": {
   "type": "object",
   "additionalProperties": false,
   "required": [
    "scope"
   ],
   "properties": {
    "scope": {
     "enum": [
      "day",
      "range",
      "next",
      "overdue",
      "inbox",
      "search",
      "recurring"
     ]
    },
    "when": {
     "$ref": "#/definitions/when"
    },
    "named_range": {
     "enum": [
      "this_week",
      "next_week",
      "this_month",
      "next_month"
     ]
    },
    "span_days": {
     "type": "integer"
    },
    "text": {
     "type": "string"
    },
    "include_done": {
     "type": "boolean"
    },
    "detail": {
     "enum": [
      "digest",
      "count",
      "first"
     ]
    }
   }
  },
  "clarification": {
   "type": "object",
   "additionalProperties": false,
   "required": [
    "question",
    "reason"
   ],
   "properties": {
    "question": {
     "type": "string",
     "description": "In Russian address the user as \"ты\" (never \"вы\")."
    },
    "reason": {
     "enum": [
      "missing_date",
      "missing_time",
      "ambiguous_date",
      "ambiguous_time",
      "ambiguous_target",
      "target_not_found",
      "unclear_speech",
      "destructive_confirm",
      "other"
     ]
    },
    "options": {
     "type": "array",
     "maxItems": 3,
     "items": {
      "type": "string"
     }
    }
   }
  }
 }
}
"""#

    /// Single-line form for the command line.
    public static var compact: String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: out, as: UTF8.self)
    }
}
