.providers = ((.providers // {}) + {"lego-claude": $p[0], "lego-claude-direct": $d[0]})
# The user owns the OpenAI models and authentication. Only its route is managed.
| if $r[0] != null and (.providers | has("lego-openai")) then
    if (.providers["lego-openai"].api == "openai-responses" or
        .providers["lego-openai"].api == "openai-completions") then
      .providers["lego-openai-direct"] = (
        .providers["lego-openai"]
        | .baseUrl = $r[0].directBaseUrl
        | .headers = ((.headers // {}) | del(.["x-headroom-cwd"]))
      )
      | .providers["lego-openai"] |= (
          .baseUrl = $r[0].baseUrl
          | .headers = ((.headers // {}) + $r[0].headers)
        )
    else
      . as $document
      | "pi: skipping lego-openai route: unsupported API\n"
      | stderr
      | $document
    end
  else . end
