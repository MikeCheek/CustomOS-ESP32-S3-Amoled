import 'package:shared_preferences/shared_preferences.dart';

/// Which notifications are worth a buzz on the watch (Notifications > "Buzz
/// only for what matters"): a person writing to you, a code, a call, a
/// delivery, a reminder - not promotions, busy group chats or likes. The
/// rest still go to the watch, quietly ({"t":"ntf",...,"q":1}): into the list
/// and Catch me up, with no toast and no vibration. Rules only, so it's
/// instant and the same every time.
class NotifPriority {
  static Future<bool> enabled() async => (await SharedPreferences.getInstance()).getBool('smart_buzz') ?? true;
  static Future<void> setEnabled(bool on) async => (await SharedPreferences.getInstance()).setBool('smart_buzz', on);

  static const _chatApps = [
    'whatsapp',
    'telegram',
    'signal',
    'messages',
    'messaggi',
    'messenger',
    'sms',
    'imessage',
    'discord',
    'teams',
    'slack',
    'line',
    'viber',
    'threema',
    'wechat',
    'element',
    'google chat',
  ];
  static const _socialApps = [
    'instagram',
    'facebook',
    'tiktok',
    'x',
    'twitter',
    'linkedin',
    'reddit',
    'youtube',
    'pinterest',
    'snapchat',
  ];

  /// True: buzz. [canReply]: the app offers a reply (a conversation).
  static bool isUrgent({required String app, required String title, required String text, bool canReply = false}) {
    final a = app.toLowerCase(), t = title.toLowerCase(), b = text.toLowerCase();
    final all = '$t $b';
    bool has(String re) => RegExp(re, caseSensitive: false).hasMatch(all);

    // always: codes, calls, alarms, deliveries, money, security
    if (has(r'\b(\d{4,8})\b') && has(r'\b(code|codice|otp|verification|verifica|pin|password|login|accesso)\b'))
      return true;
    if (has(r'\b(missed call|chiamata persa|incoming call|chiamata in arrivo|calling|ti sta chiamando)\b')) return true;
    if (has(r'\b(alarm|sveglia|reminder|promemoria|meeting starts|riunione|starts in|inizia tra)\b')) return true;
    if (has(r'\b(delivered|out for delivery|arriving|courier|consegnat[oa]|in consegna|in arrivo|corriere|ritiro)\b'))
      return true;
    if (has(r'\b(payment|pagamento|transaction|transazione|charged|addebit|bonifico|declined|rifiutat)\b')) return true;
    if (has(r'\b(security|sicurezza|new sign-in|nuovo accesso|suspicious|sospett)\b')) return true;
    if (has(r'\b(urgent|urgente|asap|emergency|emergenza|subito|call me|chiamami)\b')) return true;

    // never: promotions and social noise
    if (has(
      r'(\d+\s?%\s?(off|di sconto))|\b(sale|saldi|offer|offerta|promo|discount|sconto|coupon|deal|newsletter|unsubscribe)\b',
    )) {
      return false;
    }
    if (_socialApps.contains(a) && !canReply) return false; // likes, follows, "you might know"

    // conversations: a person, not a busy group
    final chat = canReply || _chatApps.any((c) => a.contains(c));
    if (chat) {
      final group =
          RegExp(r'(\(\d+ (messages|messaggi)\)|\d+ new messages|\d+ nuovi messaggi)').hasMatch(all) ||
          title.contains(':') ||
          title.contains('@');
      if (group) return has(r'@|\?$|\b(you|tu|te|ti)\b\?'); // a group: only when it's about you
      return true;
    }
    return false; // everything else: quietly
  }
}
