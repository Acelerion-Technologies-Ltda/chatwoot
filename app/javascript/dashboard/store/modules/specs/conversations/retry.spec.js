import axios from 'axios';
import actions from '../../conversations/actions';
import types from '../../../mutation-types';

global.axios = axios;
vi.mock('axios');

describe('retry delivery status', () => {
  it.each(['failed', 'sent', 'delivered', 'read'])(
    'keeps the server status %s after retrying',
    async status => {
      const pending = {
        id: 123,
        conversation_id: 99,
        status: 'failed',
        content_attributes: { external_error: 'provider rejected recipient' },
      };
      const commit = vi.fn();
      axios.post.mockResolvedValue({ data: { ...pending, status } });
      await actions.sendMessageWithData({ commit }, pending);
      const messages = commit.mock.calls.filter(
        ([type]) => type === types.ADD_MESSAGE
      );
      expect(messages.at(-1)[1].status).toBe(status);
      expect(commit).toHaveBeenCalledWith(
        types.ADD_CONVERSATION_ATTACHMENTS,
        expect.objectContaining({ status })
      );
    }
  );
});
