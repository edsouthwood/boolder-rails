---
name: bowda-news
description: Make this week's bowda Instagram post. Covers new problems and crags on bowda.rocks, credits the visitors and admins who added them, and produces a 1080x1350 image of the best new topo with its lines drawn. Use when Ed asks for "bowda news", an Instagram/social post, or "what's new this week".
---

# bowda news

Produces one weekly digest post. The output is an image plus a caption that Ed posts by hand. Nothing is posted automatically.

## Inputs
- **Days to cover**: 7 unless Ed says otherwise ("since Tuesday", "last fortnight"). Convert to whole days.
- **Credit files**, kept outside the public repo on purpose:
  - **`~/.config/bowda-news/admins.yml`** maps admin login names to how they're credited, e.g. `jo: "@jo.climbs"` and `sam_admin: "Sam"`.
  - **`~/.config/bowda-news/credited.yml`** records visitors already credited in a post, keyed by the name exactly as typed on the site:
    ```yaml
    "Alex Example": { credit_as: "Alex", first_posted: 2026-11-16 }
    ```
  - Create either file empty (`{}`) if it's missing.
  - Never copy names from these files into the repo, commits or PRs.

## Steps

1. **Run the digest on production.** It is read-only. The main checkout is production.
   ```bash
   OUT=<scratchpad>/bowda-news-$(date +%F)
   cd /home/ed/projects/boolder-rails && RAILS_ENV=production \
     ADMINS=~/.config/bowda-news/admins.yml \
     bin/rails "news:digest[7,$OUT]"
   ```
   This writes `$OUT/digest.json` and, if any new lines were drawn on public photos, `$OUT/post.jpg`.

2. **Work out credit names.** For each `credit` in the JSON:
   - `kind: admin`: use the name from `admins.yml`. If the login name isn't in it, use "the bowda team" and flag it.
   - `kind: visitor`: use `credit_as` from `credited.yml`. Otherwise use the **first name only** (the first word of the typed name) and flag it as first-time.
   - `null`: "the bowda team".

   If the photo credit printed on the image would differ from the name picked here, run step 1 again with `PHOTO_CREDIT="<name>"`. For example, the image might show a full name or a login name that should read as a first name.

3. **Nothing new?** Sometimes `counts.problems` and `counts.areas` are both 0, or there's no `featured_topo`. Tell Ed plainly and stop. Don't pad a quiet week.

4. **Show Ed:**
   - **The image.** Send `post.jpg` with SendUserFile (`display: render`).
   - **A caption**, under about 1,200 characters, in this order:
     1. A short hook line about the biggest news: a new crag first, then the hardest new problem.
     2. New crags, each with its problem count.
     3. The featured photo's problems by number, matching the numbers drawn on the image, e.g. `1. <problem>, 7a`.
     4. A few other highlights, with grade and crag.
     5. Thanks: "Thanks to Alex for the photo and lines, and Sam for mapping <crag>". Group by person and say what each did.
     6. The link: "All free at bowda.rocks". Instagram doesn't make links in captions clickable, so name the site rather than pasting long URLs.
     7. 4–6 hashtags, e.g. #dartmoorbouldering #dartmoor #bouldering #ukbouldering #granite and the crag name.

     Write it in plain British English with no hype words.
   - **A "Check before posting" list** of:
     - first-time visitor names. Nobody has opted in to being named on social media, so Ed decides each time, may prefer their Instagram handle, and may want to ask them.
     - admin login names missing from `admins.yml`;
     - anything credited to nobody.

5. **After Ed confirms he posted it**, add each newly credited visitor to `credited.yml`, using the name Ed approved and today's date. Do this only after he confirms, never before.

## Notes
- The digest counts problems the public can see now: not hidden, not on a hidden boulder, with a location, and in a published area.
  - Problems and lines on unpublished crags appear in the week their crag is published.
- "Lines" counts new lines drawn, including on older problems. "Problems" counts problems added.
- **A different photo:** run step 1 again with `TOPO=<topo id>`. The id is in the admin topo URL. The photo must be public. The caption's numbered list must then follow the numbers on that image (left to right). Read them from the topo's lines rather than from `featured_topo`.
- Code: `app/services/news_digest.rb`, `app/services/news_digest/image.rb`, `lib/tasks/news.rake`.
