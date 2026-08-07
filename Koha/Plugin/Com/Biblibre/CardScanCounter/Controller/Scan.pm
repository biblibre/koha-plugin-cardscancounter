package Koha::Plugin::Com::Biblibre::CardScanCounter::Controller::Scan;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Template;

use Koha::Plugin::Com::Biblibre::CardScanCounter;

=head1 API

=head2 Methods

=head3 page

Serves the anonymous OPAC kiosk page (GET /scan). No authentication is
required: this route deliberately has no x-koha-authorization block, which
Koha's REST API treats as public for plugin /contrib routes.

Translated the same way as the intranet configure.tt page: a TRY/PROCESS/
CATCH over Koha/Plugin/.../i18n/<LANG>.inc, falling back to default.inc.
The language comes straight from the KohaOpacLanguage cookie (not from
Koha::I18N/C4::Languages::getlanguage, which cache the detected language
per worker process - unsafe here since this route runs on a persistent
Mojolicious server shared by many patrons).

=cut

sub page {
    my $c = shift->openapi->valid_input or return;

    my $lang     = $c->cookie('KohaOpacLanguage') || '';
    my $plugin   = Koha::Plugin::Com::Biblibre::CardScanCounter->new();
    my $i18n_dir = $plugin->bundle_path . '/i18n';

    my $tt = Template->new( { ABSOLUTE => 1, ENCODING => 'UTF-8' } );
    my $output;
    $tt->process( \_kiosk_html(), { LANG => $lang, i18n_dir => $i18n_dir }, \$output )
        or die $tt->error();

    return $c->render( text => $output, format => 'html' );
}

=head3 scan

Records a card scan (POST /scan). Always replies with the same, empty 204
response, whether the card was recorded, ignored as a duplicate, or unknown
to Koha - the endpoint must not leak which cardnumbers exist.

=cut

sub scan {
    my $c = shift->openapi->valid_input or return;

    my $cardnumber = $c->req->json ? $c->req->json->{cardnumber} : undef;

    my $plugin = Koha::Plugin::Com::Biblibre::CardScanCounter->new();
    $plugin->record_scan($cardnumber);

    return $c->render( status => 204, data => '' );
}

sub _kiosk_html {
    return <<'HTML';
[%- TRY %]
    [%- PROCESS "${i18n_dir}/${LANG}.inc" %]
[%- CATCH %]
    [% PROCESS "${i18n_dir}/default.inc" %]
[%- END %]
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>[% T.kiosk_title | html %]</title>
  <link rel="stylesheet" type="text/css" href="/opac-tmpl/bootstrap/css/opac.css">
  <style>
    /* Isolated page (no OPAC header/navigation, so a patron can't wander
       off from the kiosk), but built with the same form and button
       classes as the rest of the OPAC, so it still looks like Koha. */
    html, body { height: 100%; margin: 0; }
    body {
      display: flex; align-items: center; justify-content: center;
    }
    .kiosk-box { width: 100%; max-width: 30rem; padding: 2rem; text-align: center; }
    #message { font-size: 1.5rem; margin-bottom: 1.5rem; }
  </style>
</head>
<body>
  <div class="kiosk-box">
    <div id="message">[% T.scan_prompt | html %]</div>
    <form id="scan-form">
      <div class="mb-3 text-start">
        <label for="cardnumber" class="form-label">[% T.card_number_label | html %]</label>
        <input id="cardnumber" name="cardnumber" type="text" class="form-control" autocomplete="off" autofocus>
      </div>
      <button type="submit" class="btn btn-primary w-100">[% T.confirm_button | html %]</button>
    </form>
  </div>
  <div id="thank-you-text" hidden>[% T.thank_you | html %]</div>

  <script>
    const form = document.getElementById('scan-form');
    const input = document.getElementById('cardnumber');
    const message = document.getElementById('message');
    // Read the already-translated strings back from the DOM instead of
    // re-embedding them as JS string literals, so there is no need to
    // escape translated text for JS syntax.
    const scanPrompt = message.textContent;
    const thankYou = document.getElementById('thank-you-text').textContent;

    function focusInput() { input.focus(); }
    focusInput();

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const cardnumber = input.value.trim();
      input.value = '';
      if (!cardnumber) return focusInput();

      try {
        await fetch('scan', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ cardnumber })
        });
      } catch (error) {
        // Network errors are intentionally not shown: nothing about the
        // scan outcome should be displayed on a public kiosk screen.
      }

      message.textContent = thankYou;
      setTimeout(() => {
        message.textContent = scanPrompt;
        focusInput();
      }, 1500);
    });
  </script>
</body>
</html>
HTML
}

1;
