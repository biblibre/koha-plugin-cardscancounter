package Koha::Plugin::Com::Biblibre::CardScanCounter;

use Modern::Perl;
use base qw(Koha::Plugins::Base);

use C4::Context;
use Digest::SHA  qw(hmac_sha256_hex);
use Koha::AuthUtils;
use Koha::Patrons;
use JSON::Validator::Schema::OpenAPIv2;

our $VERSION         = "1.0";
our $MINIMUM_VERSION = "25.11";

our $metadata = {
    name            => 'Card Scan Counter',
    author          => 'Biblibre',
    date_authored   => '2026-08-06',
    date_updated    => "2026-08-06",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Anonymous footfall counter from an OPAC kiosk card scan.',
    namespace       => 'cardscancounter',
};

=head1 NAME

Koha::Plugin::Com::Biblibre::CardScanCounter

=head1 DESCRIPTION

Records anonymous card scans from an OPAC kiosk page for footfall counting,
without keeping personal data longer than strictly necessary.

=cut

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'}            = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

=head2 Koha administration methods

=head3 install

Creates the dedicated table and seeds the default configuration values.

=cut

sub install {
    my ( $self, $args ) = @_;

    my $dbh   = C4::Context->dbh;
    my $table = $self->_scans_table;

    $dbh->do(
        qq{
        CREATE TABLE IF NOT EXISTS `$table` (
          `id` int(11) NOT NULL AUTO_INCREMENT COMMENT 'primary key',
          `branchcode` varchar(10) DEFAULT NULL COMMENT 'patron library at scan time',
          `categorycode` varchar(10) DEFAULT NULL COMMENT 'patron category at scan time',
          `sort1` varchar(80) DEFAULT NULL COMMENT 'patron sort1 value at scan time',
          `sort2` varchar(80) DEFAULT NULL COMMENT 'patron sort2 value at scan time',
          `scanned_at` datetime NOT NULL COMMENT 'date and time of the scan',
          `card_hash` char(64) DEFAULT NULL COMMENT 'salted hash of the scanned cardnumber, used only for same-day deduplication and purged nightly',
          PRIMARY KEY (`id`),
          KEY `card_hash_scanned_at` (`card_hash`, `scanned_at`),
          KEY `scanned_at` (`scanned_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    }
    );

    $self->store_data( { pepper => unpack( 'H*', Koha::AuthUtils::generate_salt( 'weak', 32 ) ) } )
        unless $self->retrieve_data('pepper');

    $self->store_data( { dedup_interval_minutes => 5 } )
        unless defined $self->retrieve_data('dedup_interval_minutes');

    $self->store_data( { retention_days => 90 } )
        unless defined $self->retrieve_data('retention_days');

    return 1;
}

=head3 upgrade

Mandatory even if it does nothing.

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

=head3 uninstall

Drops the dedicated table. Nothing else is kept by this plugin outside of it.

=cut

sub uninstall {
    my ( $self, $args ) = @_;

    my $dbh   = C4::Context->dbh;
    my $table = $self->_scans_table;
    $dbh->do("DROP TABLE IF EXISTS `$table`");

    return 1;
}

=head3 configure

Intranet configuration page: dedup window (minutes) and retention window (days).

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'templates/index/configure.tt' } );

        $template->param(
            dedup_interval_minutes => $self->retrieve_data('dedup_interval_minutes'),
            retention_days         => $self->retrieve_data('retention_days'),
        );

        $self->output_html( $template->output() );
    }
    else {
        my $dedup_interval_minutes = $self->_sanitize_positive_int(
            scalar $cgi->param('dedup_interval_minutes'), 5, 1439
        );
        my $retention_days = $self->_sanitize_positive_int(
            scalar $cgi->param('retention_days'), 90
        );

        $self->store_data(
            {
                dedup_interval_minutes => $dedup_interval_minutes,
                retention_days         => $retention_days,
            }
        );

        $self->go_home();
    }
}

=head2 Cron hook

=head3 cronjob_nightly

Called nightly by misc/cronjobs/plugins_nightly.pl (already scheduled in
Koha's standard crontab.example). Delegates to the two independent purges
that make up this plugin's data protection design.

=cut

sub cronjob_nightly {
    my ($self) = @_;

    $self->purge_daily_card_hashes;
    $self->purge_expired_scans;

    return 1;
}

=head3 purge_daily_card_hashes

The card hash is only needed to deduplicate scans on the day they happened;
once the day is over it no longer serves any purpose and must not be kept.
The row itself (branchcode, categorycode, sort1, sort2, timestamp) is left
untouched - only the hash is cleared.

=cut

sub purge_daily_card_hashes {
    my ($self) = @_;

    my $dbh   = C4::Context->dbh;
    my $table = $self->_scans_table;

    $dbh->do(
        qq{
        UPDATE `$table`
        SET card_hash = NULL
        WHERE card_hash IS NOT NULL
          AND scanned_at < CURDATE()
    }
    );

    return 1;
}

=head3 purge_expired_scans

Sliding purge: rows older than the configured retention window are deleted
entirely, independently of the daily hash purge above.

=cut

sub purge_expired_scans {
    my ($self) = @_;

    my $dbh            = C4::Context->dbh;
    my $table          = $self->_scans_table;
    my $retention_days = $self->retrieve_data('retention_days') // 90;

    $dbh->do(
        qq{
        DELETE FROM `$table`
        WHERE scanned_at < DATE_SUB(NOW(), INTERVAL ? DAY)
    },
        undef, $retention_days
    );

    return 1;
}

=head2 REST API hooks

=head3 api_namespace

=cut

sub api_namespace {
    my ($self) = @_;

    return 'cardscancounter';
}

=head3 api_routes

=cut

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_dir = $self->mbf_dir();

    my $schema = JSON::Validator::Schema::OpenAPIv2->new;
    my $spec   = $schema->resolve( $spec_dir . '/openapi.yaml' );

    return $self->_convert_refs_to_absolute( $spec->data->{'paths'}, 'file://' . $spec_dir . '/' );
}

=head3 template_include_paths

Lets C4::Templates find this plugin's i18n/*.inc files (referenced from
configure.tt as "Koha/Plugin/Com/Biblibre/CardScanCounter/i18n/${LANG}.inc")
by adding this Koha instance's pluginsdir(s) to the Template Toolkit
INCLUDE_PATH.

=cut

sub template_include_paths {
    my ($self) = @_;

    my $pluginsdir = C4::Context->config('pluginsdir');
    my @pluginsdir = ref($pluginsdir) eq 'ARRAY' ? @$pluginsdir : $pluginsdir;

    return \@pluginsdir;
}

sub _convert_refs_to_absolute {
    my ( $self, $hashref, $path_prefix ) = @_;

    foreach my $key ( keys %{$hashref} ) {
        if ( $key eq '$ref' ) {
            if ( $hashref->{$key} =~ /^(\.\/)?openapi/ ) {
                $hashref->{$key} = $path_prefix . $hashref->{$key};
            }
        }
        elsif ( ref $hashref->{$key} eq 'HASH' ) {
            $hashref->{$key} = $self->_convert_refs_to_absolute( $hashref->{$key}, $path_prefix );
        }
        elsif ( ref( $hashref->{$key} ) eq 'ARRAY' ) {
            $hashref->{$key} = $self->_convert_array_refs_to_absolute( $hashref->{$key}, $path_prefix );
        }
    }
    return $hashref;
}

sub _convert_array_refs_to_absolute {
    my ( $self, $arrayref, $path_prefix ) = @_;

    my @res;
    foreach my $item ( @{$arrayref} ) {
        if ( ref($item) eq 'HASH' ) {
            $item = $self->_convert_refs_to_absolute( $item, $path_prefix );
        }
        elsif ( ref($item) eq 'ARRAY' ) {
            $item = $self->_convert_array_refs_to_absolute( $item, $path_prefix );
        }
        push @res, $item;
    }
    return \@res;
}

=head2 Business logic

=head3 record_scan

    $plugin->record_scan($cardnumber);

Records one card scan, unless the card is unknown to Koha or was already
scanned within the configured deduplication window. Never dies on a bad or
unknown cardnumber - the caller (the API controller) always replies the same
way regardless of the outcome, so that the endpoint cannot be used to probe
which cardnumbers exist.

=cut

sub record_scan {
    my ( $self, $cardnumber ) = @_;

    return unless defined $cardnumber && length $cardnumber;

    my $patron = Koha::Patrons->find( { cardnumber => $cardnumber } );
    return unless $patron;

    my $pepper = $self->retrieve_data('pepper');
    my $hash   = hmac_sha256_hex( $cardnumber, $pepper );

    my $dbh   = C4::Context->dbh;
    my $table = $self->_scans_table;

    my $interval_minutes = $self->retrieve_data('dedup_interval_minutes') // 5;

    my ($recent) = $dbh->selectrow_array(
        qq{
        SELECT 1 FROM `$table`
        WHERE card_hash = ?
          AND scanned_at > DATE_SUB(NOW(), INTERVAL ? MINUTE)
        LIMIT 1
    },
        undef, $hash, $interval_minutes
    );

    return if $recent;

    $dbh->do(
        qq{
        INSERT INTO `$table` (branchcode, categorycode, sort1, sort2, scanned_at, card_hash)
        VALUES (?, ?, ?, ?, NOW(), ?)
    },
        undef,
        $patron->branchcode, $patron->categorycode, $patron->sort1, $patron->sort2, $hash
    );

    return 1;
}

=head2 Internal helpers

=head3 _scans_table

Computed on demand rather than cached at construction time, because
Koha::Plugins::Base::new() calls install() before returning control to this
class's own new(), so any state set after SUPER::new() would not yet exist
the first time install() runs.

=cut

sub _scans_table {
    my ($self) = @_;

    return $self->get_qualified_table_name('scans');
}

=head3 _sanitize_positive_int

    my $value = $self->_sanitize_positive_int( $input, $default, $max );

Returns $input if it is a positive integer (optionally capped at $max),
otherwise $default.

=cut

sub _sanitize_positive_int {
    my ( $self, $value, $default, $max ) = @_;

    return $default unless defined $value && $value =~ /^\d+$/ && $value >= 1;
    return $max      if defined $max && $value > $max;
    return $value;
}

1;
