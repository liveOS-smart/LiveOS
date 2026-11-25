# Google Calendar für LiveOS einrichten

Die LiveOS-Kalenderintegration wird serverseitig über die Supabase Edge Function `google-calendar-sync` betrieben. Der Google-Client-Secret und Refresh-Tokens gehören **niemals** in `index.html`, GitHub oder andere öffentliche Dateien.

## 1. Google Cloud vorbereiten

1. Öffne die [Google Cloud Console](https://console.cloud.google.com/).
2. Lege ein Projekt an oder wähle ein vorhandenes Projekt.
3. Aktiviere die **Google Calendar API**.
4. Richte den OAuth-Zustimmungsbildschirm ein. Für den privaten Testbetrieb kannst du den Veröffentlichungsstatus zunächst auf „Testing“ lassen und dein Google-Konto als Testnutzer hinzufügen.
5. Erstelle unter „Clients“ eine OAuth-Client-ID vom Typ **Web application**.

## 2. Exakte Weiterleitungsadresse eintragen

Füge diese Adresse bei den autorisierten Weiterleitungs-URIs des OAuth-Clients ein:

```text
https://hwopliqwicmzpeuvzvlk.supabase.co/functions/v1/google-calendar-sync
```

Die Adresse muss exakt mit der Callback-Adresse übereinstimmen, die die Edge Function verwendet.

## 3. Zugangsdaten sicher in Supabase hinterlegen

Öffne das [LiveOS-Supabase-Projekt](https://supabase.com/dashboard/project/hwopliqwicmzpeuvzvlk/functions/secrets) und füge unter Edge Function Secrets diese beiden Werte hinzu:

| Secret-Name | Wert |
| --- | --- |
| `GOOGLE_CLIENT_ID` | OAuth-Client-ID aus Google Cloud |
| `GOOGLE_CLIENT_SECRET` | OAuth-Client-Secret aus Google Cloud |

Optional kannst du diese Werte ebenfalls setzen; die Funktion verwendet dieselben Standardwerte, wenn sie fehlen:

| Secret-Name | Standardwert |
| --- | --- |
| `LIVEOS_APP_URL` | `https://liveos-smart.github.io/LiveOS/` |
| `GOOGLE_REDIRECT_URI` | `https://hwopliqwicmzpeuvzvlk.supabase.co/functions/v1/google-calendar-sync` |
| `GOOGLE_CALENDAR_WEBHOOK_URL` | `https://hwopliqwicmzpeuvzvlk.supabase.co/functions/v1/google-calendar-sync` |

Die beiden Google-Secrets reichen für die Standardkonfiguration aus. Nach dem Speichern sind Edge-Function-Secrets unmittelbar verfügbar; ein erneutes Deployment ist nicht nötig.

## 4. Verbindung in LiveOS herstellen

1. LiveOS öffnen und anmelden.
2. Die Kalenderseite öffnen.
3. Im Bereich „Kalender-Verknüpfung“ das Plugin aktivieren.
4. „Google-Konto verbinden“ antippen und den Zugriff erlauben.

LiveOS synchronisiert neue und gelöschte Termine in beide Richtungen. Google-Änderungen werden über Google Calendar Push Notifications angestoßen; zusätzlich gleicht LiveOS beim Öffnen und während einer aktiven Sitzung regelmäßig ab.

## Hinweise

- Die Verbindung nutzt den Google-Hauptkalender (`primary`).
- Android- und Apple-Kalender lassen sich weiterhin über den `.ics`-Export importieren. Das ist kein nativer Zwei-Wege-Abgleich mit den lokalen Geräte-Kalendern.
- Google-Push-Kanäle laufen nach einigen Tagen ab und werden bei späteren Synchronisierungen erneuert.
- Für eine öffentliche Verteilung kann Google eine Überprüfung des OAuth-Zustimmungsbildschirms und der angeforderten Kalenderberechtigungen verlangen.
- Trenne Google später in LiveOS, um die Freigabe zu widerrufen. Refresh-Tokens werden nur in den privaten Supabase-Tabellen gespeichert.
