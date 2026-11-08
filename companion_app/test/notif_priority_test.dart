import 'package:flutter_test/flutter_test.dart';
import 'package:amoled_companion/services/notif_priority.dart';

void main() {
  bool u(String app, String title, String text, {bool reply = false}) =>
      NotifPriority.isUrgent(app: app, title: title, text: text, canReply: reply);

  test('a person writing, a code, a delivery, a payment: buzz', () {
    expect(u('WhatsApp', 'Marco', 'Are you coming tonight?', reply: true), isTrue);
    expect(u('Messages', 'Bank', 'Your verification code is 482913'), isTrue);
    expect(u('Messaggi', 'Poste', 'Il tuo codice di accesso è 5521'), isTrue);
    expect(u('Amazon', 'Out for delivery', 'Your package arrives today'), isTrue);
    expect(u('Revolut', 'Payment', '€12.50 at Coop'), isTrue);
    expect(u('Phone', 'Missed call', 'Mamma'), isTrue);
  });

  test('promotions, social noise, busy groups: quietly', () {
    expect(u('Zalando', 'Black Friday', '50% off everything this weekend'), isFalse);
    expect(u('Amazon', 'Offerta del giorno', 'Sconto sulle cuffie'), isFalse);
    expect(u('Instagram', 'giulia_r', 'liked your photo'), isFalse);
    expect(u('WhatsApp', 'Calcetto: Luca', 'Chi porta il pallone', reply: true), isFalse);
    expect(u('WhatsApp', 'Family (12 messages)', 'Nonna: buongiorno', reply: true), isFalse);
    expect(u('Google Play', 'Update', 'Apps were updated'), isFalse);
  });

  test('a group message about you still buzzes', () {
    expect(u('WhatsApp', 'Lavoro: Sara', '@Michele can you check this?', reply: true), isTrue);
  });
}
