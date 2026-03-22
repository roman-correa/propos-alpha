// Supabase Edge Function: claude-verdict
// Deploy with: supabase functions deploy claude-verdict
// Set secret: supabase secrets set ANTHROPIC_API_KEY=your_key_here

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }

  try {
    const { prompt, evidenceSummary } = await req.json();

    const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY");
    if (!ANTHROPIC_KEY) {
      throw new Error("ANTHROPIC_API_KEY not configured");
    }

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-20250514",
        max_tokens: 800,
        system: `You are PropOS Legal AI — a strict noise violation judge for Colombian residential buildings.
You apply Resolution 0627/2006 (Colombian environmental noise law) exactly.
You respond ONLY in this exact JSON format with no other text:
{
  "verdict": "guilty" | "innocent" | "warning",
  "confidence": 0-100,
  "reasoning": "one sentence plain language explanation in the same language as the input",
  "findings": ["finding 1", "finding 2", "finding 3"],
  "fine_multiplier": 1 | 2 | 3
}`,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!response.ok) {
      const err = await response.text();
      throw new Error(`Anthropic API error: ${response.status} ${err}`);
    }

    const data = await response.json();
    const text = data.content?.[0]?.text || "{}";
    const clean = text.replace(/```json|```/g, "").trim();
    const verdict = JSON.parse(clean);

    return new Response(JSON.stringify({ verdict, ok: true }), {
      headers: { ...CORS, "Content-Type": "application/json" },
    });

  } catch (error) {
    console.error("claude-verdict error:", error.message);
    return new Response(
      JSON.stringify({ ok: false, error: error.message }),
      {
        status: 500,
        headers: { ...CORS, "Content-Type": "application/json" },
      }
    );
  }
});
