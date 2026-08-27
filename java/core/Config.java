package voxgig.univecsdk.core;

import java.util.Map;

import voxgig.univecsdk.utility.Json;

/** Static SDK configuration and by-name feature construction. */
@SuppressWarnings({"unchecked"})
public final class Config {

  private Config() {}

  public static Map<String, Object> makeConfig() {
    return (Map<String, Object>) Json.parse(configJson());
  }

  // SHARED CONFIG (sdkgen rung L2).
  //
  // The SDK reads the config on every request and never writes to it, so one
  // instance is shared by every client rather than rebuilt per client - the
  // difference between parsing the embedded JSON once and once per client.
  //
  // Initialization-on-demand holder: the JLS guarantees the class initializer
  // runs once, lazily, and safely under concurrency, with no locking on the
  // read path.
  private static final class SharedHolder {
    static final Map<String, Object> VALUE = makeConfig();
  }

  // The process-wide config, built once on first use.
  //
  // The returned map is SHARED: treat it as read-only. Callers that need to
  // mutate should use makeConfig, which always parses a fresh copy.
  public static Map<String, Object> sharedConfig() {
    return SharedHolder.VALUE;
  }

  public static Feature makeFeature(String name) {
    switch (name) {
      case "test":
        return new voxgig.univecsdk.feature.TestFeature();
      default:
        return new voxgig.univecsdk.feature.BaseFeature();
    }
  }

  private static String configJson() {
    StringBuilder b = new StringBuilder();
    b.append("{");
    b.append(" \"main\": {");
    b.append("  \"name\": \"Univec\",");
    b.append("  \"slug\": \"univec\",");
    b.append("  \"version\": \"0.1.1\",");
    b.append("  \"target\": \"java\"");
    b.append(" },");
    b.append(" \"feature\": {");
    b.append("  \"test\": {");
    b.append("   \"options\": {");
    b.append("    \"active\": false");
    b.append("   },");
    b.append("   \"transport\": \"base\"");
    b.append("  }");
    b.append(" },");
    b.append(" \"options\": {");
    b.append("  \"base\": \"https://api.univec.ai\",");
    b.append("  \"auth\": {");
    b.append("   \"prefix\": \"Bearer\"");
    b.append("  },");
    b.append("  \"headers\": {");
    b.append("   \"content-type\": \"application/json\"");
    b.append("  },");
    b.append("  \"entity\": {");
    b.append("   \"convert\": {},");
    b.append("   \"embed\": {},");
    b.append("   \"ephemeral_key\": {},");
    b.append("   \"model\": {}");
    b.append("  }");
    b.append(" },");
    b.append(" \"entity\": {");
    b.append("  \"convert\": {");
    b.append("   \"fields\": [");
    b.append("    {");
    b.append("     \"name\": \"bridge_model\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Embed model used to vectorise the text before translation.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"embeddings\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Translated vectors, in the target model's dimension.\",");
    b.append("     \"type\": \"`$ARRAY`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"source_model\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Model space the supplied vectors are currently in.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"target_model\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Model space to translate into.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"texts\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Texts to embed and translate.\",");
    b.append("     \"type\": \"`$ARRAY`\"");
    b.append("    }");
    b.append("   ],");
    b.append("   \"name\": \"convert\",");
    b.append("   \"op\": {");
    b.append("    \"create\": {");
    b.append("     \"input\": \"data\",");
    b.append("     \"name\": \"create\",");
    b.append("     \"points\": [");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/convert\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"convert\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      },");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/embed-bridge\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"embed-bridge\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      },");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/ephemeral/convert\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"ephemeral\",");
    b.append("        \"convert\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      },");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/ephemeral/embed-bridge\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"ephemeral\",");
    b.append("        \"embed-bridge\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      }");
    b.append("     ]");
    b.append("    }");
    b.append("   },");
    b.append("   \"relations\": {");
    b.append("    \"ancestors\": []");
    b.append("   }");
    b.append("  },");
    b.append("  \"embed\": {");
    b.append("   \"fields\": [");
    b.append("    {");
    b.append("     \"name\": \"embeddings\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"One vector per input text, in input order.\",");
    b.append("     \"type\": \"`$ARRAY`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"model\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Model that produced the vectors.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"texts\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Texts to embed.\",");
    b.append("     \"type\": \"`$ARRAY`\"");
    b.append("    }");
    b.append("   ],");
    b.append("   \"name\": \"embed\",");
    b.append("   \"op\": {");
    b.append("    \"create\": {");
    b.append("     \"input\": \"data\",");
    b.append("     \"name\": \"create\",");
    b.append("     \"points\": [");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/embed\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"embed\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      },");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/ephemeral/embed\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"ephemeral\",");
    b.append("        \"embed\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      }");
    b.append("     ]");
    b.append("    }");
    b.append("   },");
    b.append("   \"relations\": {");
    b.append("    \"ancestors\": []");
    b.append("   }");
    b.append("  },");
    b.append("  \"ephemeral_key\": {");
    b.append("   \"fields\": [");
    b.append("    {");
    b.append("     \"name\": \"dailyLimit\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Calls permitted per day.\",");
    b.append("     \"type\": \"`$INTEGER`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"dailyUsed\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Calls already used today.\",");
    b.append("     \"type\": \"`$INTEGER`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"key\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"The ephemeral API key, prefixed `eph_`.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"resetsAt\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"When the daily allowance resets.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    }");
    b.append("   ],");
    b.append("   \"name\": \"ephemeral_key\",");
    b.append("   \"op\": {");
    b.append("    \"create\": {");
    b.append("     \"input\": \"data\",");
    b.append("     \"name\": \"create\",");
    b.append("     \"points\": [");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"POST\",");
    b.append("       \"orig\": \"/v1/ephemeral/key\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"ephemeral\",");
    b.append("        \"key\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      }");
    b.append("     ]");
    b.append("    }");
    b.append("   },");
    b.append("   \"relations\": {");
    b.append("    \"ancestors\": []");
    b.append("   }");
    b.append("  },");
    b.append("  \"model\": {");
    b.append("   \"fields\": [");
    b.append("    {");
    b.append("     \"name\": \"eval\",");
    b.append("     \"short\": \"Retrieval-fidelity metrics for a convert model.\",");
    b.append("     \"type\": \"`$OBJECT`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"executionProvider\",");
    b.append("     \"short\": \"Hardware backend, e.g.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"modelCard\",");
    b.append("     \"short\": \"Convert models only: training provenance and architecture detail.\",");
    b.append("     \"type\": \"`$OBJECT`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"modelType\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"`embed` for text-to-vector models, `convert` for space-translation models.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"name\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Model identifier used in requests.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"sequenceLen\",");
    b.append("     \"short\": \"Embed models only: maximum input sequence length.\",");
    b.append("     \"type\": \"`$INTEGER`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"sourceDim\",");
    b.append("     \"short\": \"Convert models only: source vector dimension.\",");
    b.append("     \"type\": \"`$INTEGER`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"sourceModel\",");
    b.append("     \"short\": \"Convert models only: the source model space.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"targetDim\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"Dimension of the produced vectors.\",");
    b.append("     \"type\": \"`$INTEGER`\"");
    b.append("    },");
    b.append("    {");
    b.append("     \"name\": \"targetModel\",");
    b.append("     \"req\": true,");
    b.append("     \"short\": \"The model space produced.\",");
    b.append("     \"type\": \"`$STRING`\"");
    b.append("    }");
    b.append("   ],");
    b.append("   \"name\": \"model\",");
    b.append("   \"op\": {");
    b.append("    \"list\": {");
    b.append("     \"input\": \"data\",");
    b.append("     \"name\": \"list\",");
    b.append("     \"points\": [");
    b.append("      {");
    b.append("       \"args\": {},");
    b.append("       \"kind\": \"http\",");
    b.append("       \"method\": \"GET\",");
    b.append("       \"orig\": \"/v1/models\",");
    b.append("       \"parts\": [");
    b.append("        \"v1\",");
    b.append("        \"models\"");
    b.append("       ],");
    b.append("       \"select\": {},");
    b.append("       \"transform\": {");
    b.append("        \"req\": \"`reqdata`\",");
    b.append("        \"res\": \"`body.data`\"");
    b.append("       }");
    b.append("      }");
    b.append("     ]");
    b.append("    }");
    b.append("   },");
    b.append("   \"relations\": {");
    b.append("    \"ancestors\": []");
    b.append("   }");
    b.append("  }");
    b.append(" }");
    b.append("}");
    return b.toString();
  }
}
