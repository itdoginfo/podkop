import { describe, expect, it } from 'vitest';
import { newFeeds, parseFeedList } from '../feedList';

describe('parseFeedList', () => {
  it('reads the answer', () => {
    expect(
      parseFeedList(
        JSON.stringify({ ok: true, urls: ['https://a.example/x', 'junk'] }),
      ),
    ).toEqual({ ok: true, urls: ['https://a.example/x'] });
  });

  it('reads an error', () => {
    expect(parseFeedList({ ok: false, error: 'no' })).toEqual({
      ok: false,
      urls: [],
      error: 'no',
    });
  });

  it('survives garbage', () => {
    expect(parseFeedList('Usage: netshift').ok).toBe(false);
    expect(parseFeedList(null).ok).toBe(false);
    expect(parseFeedList({ ok: true }).ok).toBe(false);
  });
});

describe('newFeeds', () => {
  it('leaves out what is already there and repeats', () => {
    expect(
      newFeeds(
        ['https://a.example/x'],
        ['https://a.example/x', 'https://b.example/y', 'https://b.example/y'],
      ),
    ).toEqual(['https://b.example/y']);
  });

  it('keeps the order', () => {
    expect(newFeeds([], ['https://b/1', 'https://a/2'])).toEqual([
      'https://b/1',
      'https://a/2',
    ]);
  });
});
