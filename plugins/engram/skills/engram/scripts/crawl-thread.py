#!/usr/bin/env python3
"""Crawl an X/Twitter thread via the fxtwitter API.

Takes any tweet URL from a thread, walks backwards to the root tweet
(following self-replies), then outputs the full thread as markdown
in chronological order.

Usage:
    crawl-thread.py <tweet-url>

The fxtwitter API is public and requires no authentication.
Rate limiting: 300ms delay between API calls to be polite.
"""

import json
import re
import sys
import time
import urllib.error
import urllib.request

# -- Constants ----------------------------------------------------------------

FXTWITTER_API = "https://api.fxtwitter.com"
RATE_LIMIT_DELAY = 0.3  # seconds between API calls
MAX_THREAD_LENGTH = 100  # safety cap to prevent infinite loops
REQUEST_TIMEOUT = 15  # seconds per HTTP request


# -- HTTP helpers -------------------------------------------------------------

def fetch_tweet(author, status_id):
    """Fetch a single tweet from the fxtwitter API.

    Returns the tweet dict on success, or None on failure.
    """
    url = f"{FXTWITTER_API}/{author}/status/{status_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "crawl-thread/1.0"})

    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(f"Error: HTTP {exc.code} fetching {url}", file=sys.stderr)
        return None
    except urllib.error.URLError as exc:
        print(f"Error: could not reach {url} — {exc.reason}", file=sys.stderr)
        return None
    except json.JSONDecodeError:
        print(f"Error: invalid JSON from {url}", file=sys.stderr)
        return None

    if data.get("code") != 200:
        print(f"Error: API returned code {data.get('code')} for {url}", file=sys.stderr)
        return None

    return data.get("tweet")


# -- URL parsing --------------------------------------------------------------

def parse_tweet_url(url):
    """Extract (author, status_id) from a tweet URL.

    Supports x.com, twitter.com, fxtwitter.com, and vxtwitter.com URLs.
    Returns (author, status_id) or raises ValueError.
    """
    pattern = r"https?://(?:(?:www\.)?(?:x|twitter|fxtwitter|vxtwitter)\.com)/(\w+)/status/(\d+)"
    match = re.match(pattern, url)
    if not match:
        raise ValueError(
            f"Invalid tweet URL: {url}\n"
            "Expected format: https://x.com/<user>/status/<id>"
        )
    return match.group(1), match.group(2)


# -- Thread crawling ----------------------------------------------------------

def crawl_thread(author, status_id):
    """Walk backwards from the given tweet to the thread root, then return
    the full chain in chronological order.

    Only follows self-replies (where replying_to matches the tweet author).
    """
    tweets = []
    current_id = status_id
    seen_ids = set()

    while current_id and current_id not in seen_ids and len(tweets) < MAX_THREAD_LENGTH:
        seen_ids.add(current_id)

        tweet = fetch_tweet(author, current_id)
        if tweet is None:
            print(
                f"Warning: could not fetch tweet {current_id}, stopping walk",
                file=sys.stderr,
            )
            break

        tweets.append(tweet)

        # Walk backwards only if this is a self-reply (same author)
        parent_author = tweet.get("replying_to")
        parent_id = tweet.get("replying_to_status")

        if parent_id and parent_author and parent_author.lower() == author.lower():
            current_id = parent_id
            time.sleep(RATE_LIMIT_DELAY)
        else:
            # Reached the root (not a self-reply, or no parent)
            break

    if len(tweets) >= MAX_THREAD_LENGTH:
        print(
            f"Warning: hit max thread length ({MAX_THREAD_LENGTH}), stopping",
            file=sys.stderr,
        )

    # Reverse so tweets are in chronological order (root first)
    tweets.reverse()
    return tweets


# -- Markdown formatting ------------------------------------------------------

def format_media(media):
    """Format media attachments as markdown."""
    if not media or not media.get("all"):
        return ""

    lines = []
    for item in media["all"]:
        media_type = item.get("type", "unknown")
        url = item.get("url", "")
        if media_type == "photo":
            lines.append(f"![photo]({url})")
        elif media_type == "video":
            lines.append(f"[Video]({url})")
        elif media_type == "gif":
            lines.append(f"[GIF]({url})")
        else:
            lines.append(f"[{media_type}]({url})")
    return "\n".join(lines)


def format_engagement(tweet):
    """Format engagement counts as a compact string."""
    parts = []
    likes = tweet.get("likes", 0)
    retweets = tweet.get("retweets", 0)
    views = tweet.get("views", 0)

    if views:
        parts.append(f"{views:,} views")
    if likes:
        parts.append(f"{likes:,} likes")
    if retweets:
        parts.append(f"{retweets:,} retweets")

    return " · ".join(parts) if parts else ""


def format_thread_as_markdown(tweets):
    """Convert a list of tweet dicts into a formatted markdown string."""
    if not tweets:
        return "No tweets found."

    first = tweets[0]
    author_name = first.get("author", {}).get("name", "Unknown")
    author_handle = first.get("author", {}).get("screen_name", "unknown")
    created_at = first.get("created_at", "Unknown date")

    lines = [
        f"# Thread by @{author_handle} ({author_name})",
        f"**Date:** {created_at}",
        f"**Tweets:** {len(tweets)}",
        f"**Source:** {first.get('url', 'N/A')}",
        "",
        "---",
        "",
    ]

    for i, tweet in enumerate(tweets, 1):
        text = tweet.get("text", "")
        tweet_date = tweet.get("created_at", "")
        engagement = format_engagement(tweet)
        media_md = format_media(tweet.get("media"))
        tweet_url = tweet.get("url", "")

        lines.append(f"### {i}/{len(tweets)}")
        lines.append("")
        lines.append(text)
        lines.append("")

        if media_md:
            lines.append(media_md)
            lines.append("")

        # Metadata line
        meta_parts = []
        if tweet_date:
            meta_parts.append(tweet_date)
        if engagement:
            meta_parts.append(engagement)
        if tweet_url:
            meta_parts.append(f"[link]({tweet_url})")

        if meta_parts:
            lines.append(f"*{' · '.join(meta_parts)}*")
            lines.append("")

        lines.append("---")
        lines.append("")

    return "\n".join(lines)


# -- Main ---------------------------------------------------------------------

def main():
    if len(sys.argv) != 2:
        print("Usage: crawl-thread.py <tweet-url>", file=sys.stderr)
        sys.exit(1)

    url = sys.argv[1].strip()

    try:
        author, status_id = parse_tweet_url(url)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

    print(f"Crawling thread from @{author}, starting at tweet {status_id}...", file=sys.stderr)

    tweets = crawl_thread(author, status_id)

    if not tweets:
        print("Error: no tweets retrieved.", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(tweets)} tweets in thread.", file=sys.stderr)

    # Warn if the input tweet appears to be the thread root — the backward
    # walk can't discover tweets *after* the input, so threads started from
    # the first tweet will only capture that one tweet.
    root_id = tweets[0].get("id") or tweets[0].get("id_str") or ""
    if str(root_id) == status_id and len(tweets) == 1:
        print(
            "\n\u26a0 This appears to be the first tweet in a thread. Only captured 1 tweet.\n"
            "  For full threads, pass a URL from later in the thread (e.g., the last reply).\n",
            file=sys.stderr,
        )

    markdown = format_thread_as_markdown(tweets)
    print(markdown)


if __name__ == "__main__":
    main()
