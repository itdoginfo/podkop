import { describe, expect, it } from 'vitest';
import constants from '../../../../../../netshift/files/usr/lib/constants.sh?raw';
import { SUBSCRIPTION_FEED_GROUP_TAG_PREFIX } from '../buildSubscriptionOutboundGroup';

// The dashboard finds per-subscription blocks by the tag prefix the backend
// writes. If the two copies drift apart, the blocks silently disappear.
describe('SUBSCRIPTION_FEED_GROUP_TAG_PREFIX', () => {
  it('matches SB_SUBSCRIPTION_FEED_GROUP_TAG_PREFIX in constants.sh', () => {
    const match = constants.match(
      /^SB_SUBSCRIPTION_FEED_GROUP_TAG_PREFIX="([^"]*)"$/m,
    );

    expect(match?.[1]).toBe(SUBSCRIPTION_FEED_GROUP_TAG_PREFIX);
  });
});
