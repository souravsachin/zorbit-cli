describe('register-event', () => {
  const EVENT_NAME_PATTERN = /^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$/;

  describe('event name validation', () => {
    it('should accept valid event names', () => {
      const validNames = [
        'identity.user.created',
        'policy.claim.submitted',
        'ai.request.completed',
        'document.file.uploaded',
        'audit.log-entry.created',
      ];

      for (const name of validNames) {
        expect(EVENT_NAME_PATTERN.test(name)).toBe(true);
      }
    });

    it('should reject invalid event names', () => {
      const invalidNames = [
        'identity.user',           // only 2 parts
        'Identity.User.Created',   // uppercase
        '.user.created',           // starts with dot
        'identity..created',       // empty part
        'identity.user.created.',  // trailing dot
        '123.user.created',        // starts with number
        'identity.user.created.extra', // 4 parts
      ];

      for (const name of invalidNames) {
        expect(EVENT_NAME_PATTERN.test(name)).toBe(false);
      }
    });
  });

  describe('event name parsing', () => {
    it('should correctly split event name into domain, entity, action', () => {
      const eventName = 'identity.user.created';
      const parts = eventName.split('.');

      expect(parts[0]).toBe('identity');
      expect(parts[1]).toBe('user');
      expect(parts[2]).toBe('created');
    });
  });
});
