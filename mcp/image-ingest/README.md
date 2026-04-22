# Image Ingest MCP (stub — Phase 5)

Custom MCP server for image ingestion, understanding, and vector search.
Elasticsearch is the backing store with a dedicated index (`images_v1`).

## Stack

| Concern        | Tool |
|----------------|------|
| OCR            | Tesseract (local), with optional PaddleOCR fallback for mixed-language |
| Captioning     | BLIP-2 local, with optional Claude Vision (via the Hermes vision tool) for higher-quality captions |
| Categorization | CLIP zero-shot against a configurable label set |
| Embedding      | CLIP ViT-L/14 — 768-dim dense_vector, cosine similarity |
| Storage        | Elasticsearch 8.x, index `images_v1` |

## Tools exposed

- `ingest_image(source: str, metadata: dict = {})` — URL or local path. Runs OCR + caption + CLIP embed, indexes into ES.
- `search_images_by_text(query: str, k: int = 10, filters: dict = {})` — embeds query → k-NN.
- `search_images_by_image(source: str, k: int = 10)` — embeds input image → k-NN.
- `search_images_by_ocr(query: str, k: int = 10)` — full-text over the OCR field.
- `get_image(id: str)` — returns full record.
- `delete_image(id: str)` — removes the record.

## Elasticsearch index mapping

Authored here so the schema lives in version control. Not applied yet —
applied during Phase 5 bring-up via a bootstrap call.

```json
{
  "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
  "mappings": {
    "properties": {
      "source":      { "type": "keyword" },
      "ingested_at": { "type": "date" },
      "ocr_text":    { "type": "text" },
      "caption":     { "type": "text" },
      "tags":        { "type": "keyword" },
      "metadata":    { "type": "object", "enabled": true },
      "clip_embedding": {
        "type": "dense_vector",
        "dims": 768,
        "index": true,
        "similarity": "cosine"
      }
    }
  }
}
```

## Security model

- Traffic stays on honeynet — the MCP container talks to ES at
  `elasticsearch:9200` by hostname.
- ES auth enabled (elastic:${ELASTIC_PASSWORD}). Creds resolved from
  1Password via varlock.
- Never exposed to the host / internet.

## Credentials

```
# ES password
op://Honeybot/Elasticsearch/password    (reused)

# No other secrets — all models run locally.
```

## Implementation plan

- Python 3.12 + `mcp` SDK + `elasticsearch-py` + `torch` + `transformers` + `Pillow` + `pytesseract`
- GPU optional — CLIP/BLIP-2 run on CPU fine for <100 img/day
- Image bytes cached locally in a volume to avoid re-fetching

Not implemented yet. Phase 5.
