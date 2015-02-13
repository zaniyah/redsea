#!/usr/bin/perl

# redsea RDS decoder (c) Oona Räisänen OH2EIQ
#
#
# Page numbers refer to IEC 62106, Edition 2
#

use 5.012;
use strict;
use warnings;
use utf8;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

use IPC::Cmd     qw/can_run/;
use Encode       qw/decode/;
use POSIX        qw/strftime/;
use Getopt::Std;

binmode(STDOUT, ':encoding(UTF-8)');

$| ++;

# DSP frequencies
use constant FS => 250_000;
use constant FC => 57_000;

# Booleans
use constant FALSE => 0;
use constant TRUE  => 1;

# Offset word order
use constant {
  A  => 0,
  B  => 1,
  C  => 2,
  Ci => 3,
  D  => 4,
};

# Bit masks
use constant {
  _5BIT  => 0x000001F,
  _10BIT => 0x00003FF,
  _16BIT => 0x000FFFF,
  _26BIT => 0x3FFFFFF,
  _28BIT => 0xFFFFFFF,
};


my $correct_all = FALSE;

# Some terminal control chars
use constant   RESET => "\x1B[0m";
use constant REVERSE => "\x1B[7m";

my @group_buffer;
my @group_data;
my @has_block;
my @block_has_errors;
my %options;
my %station;

my @countryISO, my @group_names, my @ptynamesUS, my @ptynames;
my @TA_descr, my @TP_descr, my @langname, my %oda_app, my @char_table;
my @rtpclass;
my $block_counter;
my $newpi, my $ednewpi;

my $pi = 0;
my $is_in_sync = FALSE;
my $verbosity = 0;
my $expected_offset;

my $is_interactive = (-t STDOUT ? TRUE : FALSE);

my $bitpipe;
my $linebuf;

commands();

init_data();

get_groups();

sub commands {

  if (!-e 'rtl_redsea') {
    print "error: looks like rtl_redsea isn't compiled. To fix that, please ".
          "run:\n\ngcc -std=gnu99 -o rtl_redsea rtl_redsea.c -lm\n";
    exit(1);
  }
  if (!can_run('rtl_fm')) {
    print "error: looks like rtl_fm is not installed!\n";
    exit(1);
  }
  if (!can_run('sox')) {
    print "error: looks like SoX is not installed!\n";
    exit(1);
  }

  getopts('hlstp:g:', \%options);

  if (exists $options{h} || ($ARGV[0] // q{}) !~ /^[\d\.]+[kMG]?$/i) {
    print
       "Usage: perl $0 [-hlst] [-p <error>] [-g <gain>] FREQ\n\n".
       "    -h          display this help and exit\n".
       "    -l          print groups in long format\n".
       "    -s          print groups in short format (default)\n".
       "    -t          print an ISO timestamp before each group\n".
       "    -g <gain>   gain (float), passed to rtl_fm\n",
       "    -p <error>  parts-per-million error, passed to rtl_fm\n",
       "    FREQ        station frequency in Hz, can be SI suffixed (94.0M)\n\n";
    exit();
  }

  if (exists $options{l}) {
    $verbosity = 1;
  }

  my $fmfreq = $ARGV[0];
  if ($fmfreq =~ /^([\d\.]+)([kMG])$/i) {
    my %si = ( 'k' => 1e3, 'K' => 1e3, 'm' => 1e6,
               'M' => 1e6, 'g' => 1e9, 'G' => 1e9 );
    $fmfreq = $1 * $si{$2};
  }

  my $gain = (exists $options{g} ? sprintf(' -g %.2f ', $options{g}) : q{});
  my $ppm  = (exists $options{p} ? sprintf(' -p %.0f ', $options{p}) : q{});

  open $bitpipe, '-|', sprintf('rtl_fm -f %.1f -M fm -l 0 -A std '.
                       $gain.$ppm.' -s %.1f |'.
                       'sox -c 1 -t .s16 -r 250000 - -t .f32 - '.
                       'sinc -t 2000 %.1f-%.1f gain 15 2>/dev/null | '.
                       './rtl_redsea',
                       $fmfreq, FS, FC-2000, FC+2000) or die($!);
}

# Next bit from radio
sub get_bit {
  my $bit;
  read $bitpipe, $bit, 1 or die 'End of stream';
  return $bit;
}

# Calculate the syndrome of a 26-bit vector
sub syndrome {
  my $vector = shift;

  my ($l, $bit);
  my $synd_reg = 0x000;

  for my $k (reverse(0..25)) {
    $bit       = ($vector  & (1 << $k));
    $l         = ($synd_reg & 0x200);      # Store lefmost bit of register
    $synd_reg  = ($synd_reg << 1) & 0x3FF; # Rotate register
    $synd_reg ^= ($bit ? 0x31B : 0x00);    # Premultiply input by x^325 mod g(x)
    $synd_reg ^= ($l   ? 0x1B9 : 0x00);    # Division mod 2 by g(x)
  }

  return $synd_reg;
}


# When a block has uncorrectable errors, dump the group received so far
sub blockerror {
  my $data_length = 0;

  if ($has_block[A]) {
    $data_length = 1;

    if ($has_block[B]) {
      $data_length = 2;

      if ($has_block[C] || $has_block[Ci]) {
        $data_length = 3;
      }
    }
    my @new_group;
    @new_group = @group_data[0..$data_length-1];
    push (@group_buffer, \@new_group);
  } elsif ($has_block[Ci]) {
    my @new_group;
    @new_group = $group_data[2];
    push (@group_buffer, \@new_group);
  }

  $block_has_errors[$block_counter % 50] = TRUE;

  my $erroneous_blocks = 0;
  for (@block_has_errors) {
    $erroneous_blocks += ($_ // 0);
  }

  # Sync is lost when >45 out of last 50 blocks are erroneous (C.1.2)
  if ($is_in_sync && $erroneous_blocks > 45) {
    $is_in_sync       = FALSE;
    @block_has_errors = ();
  }

  @has_block = ();
}

sub get_groups {

  my $block = my $wideblock = my $bitcount = my $prevbitcount = 0;
  my ($dist, $message);
  my $pi = my $i = 0;
  my $j = my $data_length = my $buf = my $prevsync = 0;
  my $left_to_read = 26;
  my @has_sync_for;

  my @offset_word = (0x0FC, 0x198, 0x168, 0x350, 0x1B4);
  my @ofs2block   = (0, 1, 2, 2, 3);
  my ($synd_reg, $pattern);
  my @error_lookup;

  # Generate error vector lookup table for all correctable errors
  for my $shft (0..15) {
    $pattern = 0x01 << $shft;
    $error_lookup[syndrome(0x00004b9 ^ ($pattern << 10))] = $pattern;
  }
  for my $shft (0..14) {
    $pattern = 0x11 << $shft;
    $error_lookup[syndrome(0x00004b9 ^ ($pattern << 10))] = $pattern;
  }

  if ($correct_all) {
    for ($pattern = 0x01; $pattern <= 0x1F; $pattern += 2) {
      for my $i (0..16-int(log2($pattern) + 1)) {
        my $shifted_pattern = $pattern << $i;
        $error_lookup[syndrome(0x00005b9 ^ ($shifted_pattern<<10))]
          = $shifted_pattern;
      }
    }
  }

  print STDERR "Waiting for sync\n";

  while (TRUE) {

    # Compensate for clock slip corrections
    $bitcount += 26-$left_to_read;

    # Read from radio
    for ($i=0; $i < ($is_in_sync ? $left_to_read : 1); $i++, $bitcount++) {
      $wideblock = ($wideblock << 1) + get_bit();
    }

    $left_to_read = 26;
    $wideblock &= _28BIT;

    $block = ($wideblock >> 1) & _26BIT;

    # Find the offsets for which the syndrome is zero
    for (A .. D) {
      $has_sync_for[$_] = (syndrome($block ^ $offset_word[$_]) == 0);
    }

    # Acquire sync

    if (!$is_in_sync) {

      if ($has_sync_for[A] | $has_sync_for[B] | $has_sync_for[C] |
          $has_sync_for[Ci] | $has_sync_for[D]) {

        BLOCKS:
        for my $bnum (A .. D) {
          if ($has_sync_for[$bnum]) {
            $dist = $bitcount - $prevbitcount;

            if ($dist % 26 == 0 && $dist <= 156 &&
               ($ofs2block[$prevsync] + $dist/26) % 4 == $ofs2block[$bnum]) {
              $is_in_sync      = TRUE;
              $expected_offset = $bnum;
              last BLOCKS;
            } else {
              $prevbitcount = $bitcount;
              $prevsync     = $bnum;
            }
          }
        }
      }
    }

    # Synchronous decoding

    if ($is_in_sync) {

      $block_counter ++;

      $message = $block >> 10;

      # If expecting C but we only got a Ci sync pulse, we have a Ci block
      if ($expected_offset == C && !$has_sync_for[C] &&
          $has_sync_for[Ci]) {
        $expected_offset = Ci;
      }

      # If this block offset won't give a sync pulse
      if (!$has_sync_for[$expected_offset]) {

        # If it's a correct PI, the error was probably in the check bits and
        # hence is ignored
        if      ($expected_offset == A && $message == $pi && $pi != 0) {
          $has_sync_for[A]  = TRUE;
        } elsif ($expected_offset == C && $message == $pi && $pi != 0) {
          $has_sync_for[Ci] = TRUE;
        }

        # Detect & correct clock slips (C.1.2)

        elsif   ($expected_offset == A && $pi != 0 &&
                (($wideblock >> 12) & _16BIT ) == $pi) {
          $message           = $pi;
          $wideblock       >>= 1;
          $has_sync_for[A] = TRUE;
        } elsif ($expected_offset == A && $pi != 0 &&
                (($wideblock >> 10) & _16BIT ) == $pi) {
          $message           = $pi;
          $wideblock         = ($wideblock << 1) + get_bit();
          $has_sync_for[A] = TRUE;
          $left_to_read      = 25;
        }

        # Detect & correct burst errors (B.2.2)

        $synd_reg = syndrome($block ^ $offset_word[$expected_offset]);

        if (defined $error_lookup[$synd_reg]) {
          $message = ($block >> 10) ^ $error_lookup[$synd_reg];
          $has_sync_for[$expected_offset] = TRUE;
        }

        # If still no sync pulse
        blockerror() if (!$has_sync_for[$expected_offset]);
      }

      # Error-free block received
      if ($has_sync_for[$expected_offset]) {

        $group_data[$ofs2block[$expected_offset]] = $message;
        $block_has_errors[$block_counter % 50]    = FALSE;
        $has_block[$expected_offset]              = TRUE;

        if ($expected_offset == A) {
          $pi = $message;
        }

        # A complete group is received
        if ($has_block[A] && $has_block[B] &&
           ($has_block[C] || $has_block[Ci]) && $has_block[D]) {
          decode_group(@group_data);
        }
      }

      # The block offset we're expecting next
      $expected_offset = ($expected_offset == C ? D :
        ($expected_offset + 1) % 5);

      if ($expected_offset == A) {
        @has_block = ();
      }
    }
  }
  return FALSE;
}


sub decode_group {

  my @blocks = @_;

  return if ($blocks[0] == 0x0000);
  my ($group_type, $full_group_type);

  $ednewpi = ($newpi // 0);
  $newpi   = $blocks[0];

  if (exists $options{t}) {
    my $timestamp = strftime('%Y-%m-%dT%H:%M:%S%z ', localtime);
    utter ($timestamp, $timestamp);
  }

  if (@blocks >= 2) {
    $group_type       = extract_bits($blocks[1], 11, 5);
    $full_group_type  = extract_bits($blocks[1], 12, 4).
                       (extract_bits($blocks[1], 11, 1) ? 'B' : 'A' );
  } else {
    utter ('(PI only)', q{});
  }

  utter (('  PI:     '.sprintf('%04X',$newpi).
    ((exists($station{$newpi}{'chname'})) ?
      q{ }.$station{$newpi}{'chname'} : q{}),
      sprintf('%04X',$newpi)));

  # PI is repeated -> confirmed
  if ($newpi == $ednewpi) {

    # PI has changed from last confirmed
    if ($newpi != ($pi // 0)) {
      $pi = $newpi;
      screenReset();
      if (exists $station{$pi}{'presetPSbuf'}) {
        ($station{$pi}{'PSmarkup'}
          = $station{$pi}{'presetPSbuf'}) =~ s/&/&amp;/g;
        $station{$pi}{'PSmarkup'}  =~ s/</&lt;/g;
      }
    }

  } elsif ($newpi != ($pi // 0)) {
    utter ('          (repeat will confirm PI change)',"?\n");
    return;
  }

  # Nothing more to be done for PI only
  if (@blocks == 1) {
    utter ("\n","\n");
    return;
  }

  utter (
   (@blocks == 4 ? "Group $full_group_type: $group_names[$group_type]" :
                   "(partial group $full_group_type, ".scalar(@blocks).
                   ' blocks)'),
   (@blocks == 4 ? sprintf(' %3s', $full_group_type) :
                   sprintf(' (%3s)', $full_group_type)));

  # Traffic Program (TP)
  $station{$pi}{'TP'} = extract_bits($blocks[1], 10, 1);
  utter ('  TP:     '.$TP_descr[$station{$pi}{'TP'}],
         ' TP:'.$station{$pi}{'TP'});

  # Program Type (PTY)
  $station{$pi}{'PTY'} = extract_bits($blocks[1], 5, 5);

  if (exists $station{$pi}{'ECC'} &&
     ($countryISO[$station{$pi}{'ECC'}][$station{$pi}{'CC'}] // q{})
       =~ /us|ca|mx/) {
    $station{$pi}{'PTYmarkup'} = $ptynamesUS[$station{$pi}{'PTY'}];
    utter ("  PTY:    ". sprintf("%02d",$station{$pi}{'PTY'}).
           q{ }.$ptynamesUS[$station{$pi}{'PTY'}],
           ' PTY:'.sprintf('%02d',$station{$pi}{'PTY'}));
  } else {
    $station{$pi}{'PTYmarkup'} = $ptynames[$station{$pi}{'PTY'}];
    utter ('  PTY:    '. sprintf('%02d',$station{$pi}{'PTY'}).
           q{ }.$ptynames[$station{$pi}{'PTY'}],
           ' PTY:'.sprintf('%02d',$station{$pi}{'PTY'}));
  }
  $station{$pi}{'PTYmarkup'} =~ s/&/&amp;/g;

  # Data specific to the group type

  given ($group_type) {
    when (0)  {
      Group0A (@blocks);
    }
    when (1)  {
      Group0B (@blocks);
    }
    when (2)  {
      Group1A (@blocks);
    }
    when (3)  {
      Group1B (@blocks);
    }
    when (4)  {
      Group2A (@blocks);
    }
    when (5)  {
      Group2B (@blocks);
    }
    when (6)  {
      exists ($station{$pi}{'ODAaid'}{6})  ?
        ODAGroup(6, @blocks)  : Group3A (@blocks);
      }
    when (8)  {
      Group4A (@_);
    }
    when (10) {
      exists ($station{$pi}{'ODAaid'}{10}) ?
        ODAGroup(10, @blocks) : Group5A (@blocks);
    }
    when (11) {
      exists ($station{$pi}{'ODAaid'}{11}) ?
        ODAGroup(11, @blocks) : Group5B (@blocks);
    }
    when (12) {
      exists ($station{$pi}{'ODAaid'}{12}) ?
        ODAGroup(12, @blocks) : Group6A (@blocks);
    }
    when (13) {
      exists ($station{$pi}{'ODAaid'}{13}) ?
        ODAGroup(13, @blocks) : Group6B (@blocks);
    }
    when (14) {
      exists ($station{$pi}{'ODAaid'}{14}) ?
        ODAGroup(14, @blocks) : Group7A (@blocks);
    }
    when (18) {
      exists ($station{$pi}{'ODAaid'}{18}) ?
        ODAGroup(18, @blocks) : Group9A (@blocks);
    }
    when (20) {
      Group10A(@blocks);
    }
    when (26) {
      exists ($station{$pi}{'ODAaid'}{26}) ?
        ODAGroup(26, @blocks) : Group13A(@blocks);
    }
    when (28) {
      Group14A(@blocks);
    }
    when (29) {
      Group14B(@blocks);
    }
    when (31) {
      Group15B(@blocks);
    }

    default   {
      ODAGroup($group_type, @blocks);
    }
  }

  utter("\n","\n");

}

# 0A: Basic tuning and switching information

sub Group0A {

  my @blocks = @_;

  # DI
  my $DI_adr = 3 - extract_bits($blocks[1], 0, 2);
  my $DI     = extract_bits($blocks[1], 2, 1);
  parse_DI($DI_adr, $DI);

  # TA, M/S
  $station{$pi}{'TA'} = extract_bits($blocks[1], 4, 1);
  $station{$pi}{'MS'} = extract_bits($blocks[1], 3, 1);
  utter ('  TA:     '.
    $TA_descr[$station{$pi}{'TP'}][$station{$pi}{'TA'}],
    ' TA:'.$station{$pi}{'TA'});
  utter ('  M/S:    '.qw( Speech Music )[$station{$pi}{'MS'}],
    ' MS:'.qw(S M)[$station{$pi}{'MS'}]);

  $station{$pi}{'hasMS'} = TRUE;

  if (@blocks >= 3) {
    # AF
    my @af;
    for (0..1) {
      $af[$_] = parse_AF(TRUE, extract_bits($blocks[2], 8-$_*8, 8));
      utter ('  AF:     '.$af[$_],' AF:'.$af[$_]);
    }
    if ($af[0] =~ /follow/ && $af[1] =~ /Hz/) {
      ($station{$pi}{'freq'} = $af[1]) =~ s/ ?[kM]Hz//;
    }
  }

  if (@blocks == 4) {

    # Program Service Name (PS)

    if ($station{$pi}{'denyPS'}) {
      utter ("          (Ignoring changes to PS)"," denyPS");
    } else {
      set_PS_chars($pi, extract_bits($blocks[1], 0, 2) * 2,
        extract_bits($blocks[3], 8, 8), extract_bits($blocks[3], 0, 8));
    }
  }
}

# 0B: Basic tuning and switching information

sub Group0B {

  my @blocks = @_;

  # Decoder Identification
  my $DI_adr = 3 - extract_bits($blocks[1], 0, 2);
  my $DI     = extract_bits($blocks[1], 2, 1);
  parse_DI($DI_adr, $DI);

  # Traffic Announcements, Music/Speech
  $station{$pi}{'TA'} = extract_bits($blocks[1], 4, 1);
  $station{$pi}{'MS'} = extract_bits($blocks[1], 3, 1);
  utter ("  TA:     ".
    $TA_descr[$station{$pi}{'TP'}][$station{$pi}{'TA'}],
    " TA:$station{$pi}{'TA'}");
  utter ("  M/S:    ".qw( Speech Music )[$station{$pi}{'MS'}],
    " MS:".qw( S M)[$station{$pi}{'MS'}]);

  $station{$pi}{'hasMS'} = TRUE;

  if (@blocks == 4) {

    # Program Service name

    if ($station{$pi}{'denyPS'}) {
      utter ('          (Ignoring changes to PS)', ' denyPS');
    } else {
      set_PS_chars($pi, extract_bits($blocks[1], 0, 2) * 2,
        extract_bits($blocks[3], 8, 8), extract_bits($blocks[3], 0, 8));
    }
  }

}

# 1A: Program Item Number & Slow labeling codes

sub Group1A {

  my @blocks = @_;

  return if (@blocks < 4);

  # Program Item Number

  utter ('  PIN:    '. parse_PIN($blocks[3]),' PIN:'.parse_PIN($blocks[3]));

  # Paging (M.2.1.1.2)

  print_appdata ('Pager', 'TNG: '.     extract_bits($blocks[1], 2, 3));
  print_appdata ('Pager', 'interval: '.extract_bits($blocks[1], 0, 2));

  # Slow labeling codes

  $station{$pi}{'LA'} = extract_bits($blocks[2], 15, 1);
  utter ('  LA:     '.($station{$pi}{'LA'} ? 'Program is linked '.
    (exists($station{$pi}{'LSN'}) &&
    sprintf('to linkage set %Xh ', $station{$pi}{'LSN'})).
    'at the moment' : 'Program is not linked at the moment'),
    ' LA:'.$station{$pi}{'LA'}.(exists($station{$pi}{'LSN'})
    && sprintf('0x%X',$station{$pi}{'LSN'})));

  my $slc_variant = extract_bits($blocks[2], 12, 3);

  given ($slc_variant) {

    when (0) {
      print_appdata ('Pager', 'OPC: '.extract_bits($blocks[2], 8, 4));

      # No PIN, M.3.2.4.3
      if (@blocks == 4 && ($blocks[3] >> 11) == 0) {
        given (extract_bits($blocks[3], 10, 1)) {
          # Sub type 0
          when (0) {
            print_appdata ('Pager', 'PAC: '.extract_bits($blocks[3], 4, 6));
            print_appdata ('Pager', 'OPC: '.extract_bits($blocks[3], 0, 4));
          }
          # Sub type 1
          when (1) {
            given (extract_bits($blocks[3], 8, 2)) {
              when (0) {
                print_appdata ('Pager', 'ECC: '. extract_bits($blocks[3], 0, 6));
              }
              when (3) {
                print_appdata ('Pager', 'CCF: '.extract_bits($blocks[3], 0, 4));
              }
            }
          }
        }
      }

      $station{$pi}{'ECC'}    = extract_bits($blocks[2],  0, 8);
      $station{$pi}{'CC'}     = extract_bits($pi,   12, 4);
      utter (('  ECC:    '.sprintf('%02X', $station{$pi}{'ECC'}).
        (defined $countryISO[$station{$pi}{'ECC'}][$station{$pi}{'CC'}] &&
              " ($countryISO[$station{$pi}{'ECC'}][$station{$pi}{'CC'}])"),
           (' ECC:'.sprintf('%02X', $station{$pi}{'ECC'}).
        (defined $countryISO[$station{$pi}{'ECC'}][$station{$pi}{'CC'}] &&
              "[$countryISO[$station{$pi}{'ECC'}][$station{$pi}{'CC'}]]" ))));
    }

    when (1) {
      $station{$pi}{'tmcid'}       = extract_bits($blocks[2], 0, 12);
      utter ('  TMC ID: '. sprintf('%xh',$station{$pi}{'tmcid'}),
        ' TMCID:'.sprintf('%xh',$station{$pi}{'tmcid'}));
    }

    when (2) {
      print_appdata ('Pager', 'OPC: '.extract_bits($blocks[2], 8, 4));
      print_appdata ('Pager', 'PAC: '.extract_bits($blocks[2], 0, 6));

      # No PIN, M.3.2.4.3
      if (@blocks == 4 && ($blocks[3] >> 11) == 0) {
        given (extract_bits($blocks[3], 10, 1)) {
          # Sub type 0
          when (0) {
            print_appdata ('Pager', 'PAC: '.extract_bits($blocks[3], 4, 6));
            print_appdata ('Pager', 'OPC: '.extract_bits($blocks[3], 0, 4));
          }
          # Sub type 1
          when (1) {
            given (extract_bits($blocks[3], 8, 2)) {
              when (0) {
                print_appdata ('Pager', 'ECC: '.extract_bits($blocks[3], 0, 6));
              }
              when (3) {
                print_appdata ('Pager', 'CCF: '.extract_bits($blocks[3], 0, 4));
              }
            }
          }
        }
      }
    }

    when (3) {
      $station{$pi}{'lang'}        = extract_bits($blocks[2], 0, 8);
      utter ('  Lang:   '. sprintf( ($station{$pi}{'lang'} <= 127 ?
        "0x%X $langname[$station{$pi}{'lang'}]" : "Unknown language %Xh"),
        $station{$pi}{'lang'}),
        ' LANG:'.sprintf( ($station{$pi}{'lang'} <= 127 ?
        "0x%X[$langname[$station{$pi}{'lang'}]]" : "%Hx[?]"),
        $station{$pi}{'lang'}));
    }

    when (6) {
      utter ('  Brodcaster data: '.sprintf('%03x',
        extract_bits($blocks[2], 0, 12)),
        ' BDATA:'.sprintf('%03x', extract_bits($blocks[2], 0, 12)));
    }

    when (7) {
      $station{$pi}{'EWS_channel'} = extract_bits($blocks[2], 0, 12);
      utter ('  EWS channel: '. sprintf('0x%X',$station{$pi}{'EWS_channel'}),
             ' EWSch:'. sprintf('0x%X',$station{$pi}{'EWS_channel'}));
    }

    default {
      say "          SLC variant $slc_variant is not assigned in standard";
    }

  }
}

# 1B: Program Item Number

sub Group1B {
  my @blocks = @_;
  
  return if (@blocks < 4);

  utter ("  PIN:    ". parse_PIN($blocks[3])," PIN:$blocks[3]");
}

# 2A: RadioText (64 characters)

sub Group2A {

  my @blocks = @_;
  
  return if (@blocks < 3);

  my $text_seg_addr        = extract_bits($blocks[1], 0, 4) * 4;
  $station{$pi}{'prev_textAB'} = $station{$pi}{'textAB'};
  $station{$pi}{'textAB'}      = extract_bits($blocks[1], 4, 1);
  my @chr                  = ();

  $chr[0] = extract_bits($blocks[2], 8, 8);
  $chr[1] = extract_bits($blocks[2], 0, 8);

  if (@blocks == 4) {
    $chr[2] = extract_bits($blocks[3], 8, 8);
    $chr[3] = extract_bits($blocks[3], 0, 8);
  }

  # Page 26
  if (($station{$pi}{'prev_textAB'} // -1) != $station{$pi}{'textAB'}) {
    if ($station{$pi}{'denyRTAB'} // FALSE) {
      utter ('          (Ignoring A/B flag change)', ' denyRTAB');
    } else {
      utter ('          (A/B flag change; text reset)', ' RT_RESET');
      $station{$pi}{'RTbuf'}  = q{ } x 64;
      $station{$pi}{'RTrcvd'} = ();
    }
  }

  set_rt_chars($text_seg_addr, @chr);
}

# 2B: RadioText (32 characters)

sub Group2B {

  my @blocks = @_;

  return if (@blocks < 4);

  my $text_seg_addr            = extract_bits($blocks[1], 0, 4) * 2;
  $station{$pi}{'prev_textAB'} = $station{$pi}{'textAB'};
  $station{$pi}{'textAB'}      = extract_bits($blocks[1], 4, 1);
  my @chr                      = (extract_bits($blocks[3], 8, 8),
                                  extract_bits($blocks[3], 0, 8));

  if (($station{$pi}{'prev_textAB'} // -1) != $station{$pi}{'textAB'}) {
    if ($station{$pi}{'denyRTAB'} // FALSE) {
      utter ('          (Ignoring A/B flag change)', ' denyRTAB');
    } else {
      utter ('          (A/B flag change; text reset)', ' RT_RESET');
      $station{$pi}{'RTbuf'}  = q{ } x 64;
      $station{$pi}{'RTrcvd'} = ();
    }
  }

  set_rt_chars($text_seg_addr, @chr);

}

# 3A: Application Identification for Open Data

sub Group3A {

  my @blocks = @_;

  return if (@blocks < 4);

  my $group_type = extract_bits($blocks[1], 0, 5);

  given ($group_type) {

    when (0) {
      utter ('  ODAapp: '. ($oda_app{$blocks[3]} // sprintf('0x%04X',$blocks[3])),
             ' ODAapp:'.sprintf('0x%04X',$blocks[3]));
      utter ('          is not carried in associated group','[not_carried]');
      return;
    }

    when (32) {
      utter ('  ODA:    Temporary data fault (Encoder status)',
             ' ODA:enc_err');
      return;
    }

    when ([0..6, 8, 20, 28, 29, 31]) {
      utter ('  ODA:    (Illegal Application Group Type)',' ODA:err');
      return;
    }

    default {
      $station{$pi}{'ODAaid'}{$group_type} = $blocks[3];
      utter ('  ODAgrp: '. extract_bits($blocks[1], 1, 4).
            (extract_bits($blocks[1], 0, 1) ? 'B' : 'A'),
            ' ODAgrp:'. extract_bits($blocks[1], 1, 4).
            (extract_bits($blocks[1], 0, 1) ? 'B' : 'A'));
      utter ('  ODAapp: '. ($oda_app{$station{$pi}{'ODAaid'}{$group_type}} //
        sprintf('%04Xh',$station{$pi}{'ODAaid'}{$group_type})),
        ' ODAapp:'. sprintf('0x%04X',$station{$pi}{'ODAaid'}{$group_type}));
    }

  }

  given ($station{$pi}{'ODAaid'}{$group_type}) {

    # Traffic Message Channel
    when ([0xCD46, 0xCD47]) {
      $station{$pi}{'hasTMC'} = TRUE;
      print_appdata ('TMC', sprintf('sysmsg %04x',$blocks[2]));
    }

    # RT+
    when (0x4BD7) {
      $station{$pi}{'hasRTplus'} = TRUE;
      $station{$pi}{'rtp_which'} = extract_bits($blocks[2], 13, 1);
      $station{$pi}{'CB'}        = extract_bits($blocks[2], 12, 1);
      $station{$pi}{'SCB'}       = extract_bits($blocks[2],  8, 4);
      $station{$pi}{'templnum'}  = extract_bits($blocks[2],  0, 8);
      utter ('  RT+ applies to '.($station{$pi}{'rtp_which'} ?
        'enhanced RadioText' : 'RadioText'), q{});
      utter ('  '.($station{$pi}{'CB'} ?
        "Using template $station{$pi}{'templnum'}" : 'No template in use'),
        q{});
      if (!$station{$pi}{'CB'}) {
        utter (sprintf('  Server Control Bits: %Xh', $station{$pi}{'SCB'}),
               sprintf(' SCB:%Xh', $station{$pi}{'SCB'}));
      }
    }

    # eRT
    when (0x6552) {
      $station{$pi}{'haseRT'}     = TRUE;
      if (not exists $station{$pi}{'eRTbuf'}) {
        $station{$pi}{'eRTbuf'}     = q{ } x 64;
      }
      $station{$pi}{'ert_isutf8'} = extract_bits($blocks[2], 0, 1);
      $station{$pi}{'ert_txtdir'} = extract_bits($blocks[2], 1, 1);
      $station{$pi}{'ert_chrtbl'} = extract_bits($blocks[2], 2, 4);
    }

    # Unimplemented ODA
    default {
      say '  ODAmsg: '. sprintf('%04x',$blocks[2]);
      say '          Unimplemented Open Data Application';
    }
  }
}

# 4A: Clock-time and date

sub Group4A {

  my @blocks = @_;

  return if (@blocks < 3);

  my $lto;
  my $mjd = (extract_bits($blocks[1], 0, 2) << 15) | extract_bits($blocks[2], 1, 15);

  if (@blocks == 4) {
    # Local time offset
    $lto =  extract_bits($blocks[3], 0, 5) / 2;
    $lto = (extract_bits($blocks[3], 5, 1) ? -$lto : $lto);
    $mjd = int($mjd + $lto / 24);
  }

  my $yr  = int(($mjd - 15078.2) / 365.25);
  my $mo  = int(($mjd - 14956.1 - int($yr * 365.25)) / 30.6001);
  my $dy  = $mjd-14956 - int($yr * 365.25) - int($mo * 30.6001);
  my $k   = ($mo== 14 || $mo == 15);
  $yr += $k + 1900;
  $mo -= 1 + $k * 12;
  #$wd = ($mjd + 2) % 7;

  if (@blocks == 4) {
    my $ltom = ($lto - int($lto)) * 60;
    $lto = int($lto);

    my $hr = ( ( extract_bits($blocks[2], 0, 1) << 4) |
      extract_bits($blocks[3], 12, 4) + $lto) % 24;
    my $mn = extract_bits($blocks[3], 6, 6);

    utter ('  CT:     '. (($dy > 0 && $dy < 32 && $mo > 0 && $mo < 13 &&
          $hr > 0 && $hr < 24 && $mn > 0 && $mn < 60) ?
          sprintf('%04d-%02d-%02dT%02d:%02d%+03d:%02d', $yr, $mo, $dy, $hr,
          $mn, $lto, $ltom) : 'Invalid datetime data'),
          " CT:". (($dy > 0 && $dy < 32 && $mo > 0 && $mo < 13 && $hr > 0 &&
          $hr < 24 && $mn > 0 && $mn < 60) ?
          sprintf('%04d-%02d-%02dT%02d:%02d%+03d:%02d', $yr, $mo, $dy, $hr,
          $mn, $lto, $ltom) : "err"));
  } else {
    utter ('  CT:     '. (($dy > 0 && $dy < 32 && $mo > 0 && $mo < 13) ?
          sprintf('%04d-%02d-%02d', $yr, $mo, $dy) :
          'Invalid datetime data'),
          ' CT:'. (($dy > 0 && $dy < 32 && $mo > 0 && $mo < 13) ?
          sprintf('%04d-%02d-%02d', $yr, $mo, $dy) :
          'err'));
  }

}

# 5A: Transparent data channels or ODA

sub Group5A {

  my @blocks = @_;

  return if (@blocks < 4);

  my $addr = extract_bits($blocks[1], 0, 5);
  my $tds  = sprintf('%02x %02x %02x %02x',
    extract_bits($blocks[2], 8, 8), extract_bits($blocks[2], 0, 8),
    extract_bits($blocks[3], 8, 8), extract_bits($blocks[3], 0, 8));
  utter ('  TDChan: '.$addr, ' TDChan:'.$addr);
  utter ('  TDS:    '.$tds, ' TDS:'.$tds);
}

# 5B: Transparent data channels or ODA

sub Group5B {
  my @blocks = @_;

  return if (@blocks < 4);

  my $addr = extract_bits($blocks[1], 0, 5);
  my $tds  = sprintf('%02x %02x', extract_bits($blocks[3], 8, 8),
    extract_bits($blocks[3], 0, 8));
  utter ('  TDChan: '.$addr, ' TDChan:'.$addr);
  utter ('  TDS:    '.$tds, ' TDS:'.$tds);
}


# 6A: In-House Applications or ODA

sub Group6A {
  my @blocks = @_;

  return if (@blocks < 4);

  my $ih = sprintf('%02x %04x %04x', extract_bits($blocks[1], 0, 5), $blocks[2], $blocks[3]);
  utter ('  InHouse:'.$ih, ' IH:'.$ih);

}

# 6B: In-House Applications or ODA

sub Group6B {
  my @blocks = @_;

  return if (@blocks < 4);
  my $ih = sprintf('%02x %04x', extract_bits($blocks[1], 0, 5), $blocks[3]);
  utter ('  InHouse:'.$ih, ' IH:'.$ih);

}

# 7A: Radio Paging or ODA

sub Group7A {
  my @blocks = @_;

  return if (@blocks < 3);

  print_appdata ('Pager', sprintf('7A: %02x %04x %04x',
    extract_bits($blocks[1], 0, 5), $blocks[2], $blocks[3]));

}

# 9A: Emergency warning systems or ODA

sub Group9A {
  my @blocks = @_;

  return if (@blocks < 4);

  my $ews = sprintf('%02x %04x %04x',
    extract_bits($blocks[1], 0, 5), $blocks[2], $blocks[3]);
  utter ('  EWS:    '.$ews, ' EWS:'.$ews);

}

# 10A: Program Type Name (PTYN)

sub Group10A {
  my @blocks = @_;

  if (extract_bits($blocks[1], 4, 1) != ($station{$pi}{'PTYNAB'} // -1)) {
    utter ('         (A/B flag change, text reset)', q{});
    $station{$pi}{'PTYN'} = q{ } x 8;
  }

  $station{$pi}{'PTYNAB'} = extract_bits($blocks[1], 4, 1);

  if (@blocks >= 3) {
    my @char = ();
    $char[0] = extract_bits($blocks[2], 8, 8);
    $char[1] = extract_bits($blocks[2], 0, 8);

    if (@blocks == 4) {
      $char[2] = extract_bits($blocks[3], 8, 8);
      $char[3] = extract_bits($blocks[3], 0, 8);
    }

    my $segaddr = extract_bits($blocks[1], 0, 1);

    for my $cnum (0..$#char) {
      substr($station{$pi}{'PTYN'}, $segaddr*4 + $cnum, 1)
        = $char_table[$char[$cnum]];
    }

    my $displayed_PTYN
      = ($is_interactive ? '  PTYN:   '.
      substr($station{$pi}{'PTYN'},0,$segaddr*4).REVERSE.
      substr($station{$pi}{'PTYN'},$segaddr*4,scalar(@char)).RESET.
      substr($station{$pi}{'PTYN'},$segaddr*4+scalar(@char)) :
      $station{$pi}{'PTYN'});
    utter ('  PTYN:   '.$displayed_PTYN, q{ PTYN:"}.$displayed_PTYN.q{"});
  }
}

# 13A: Enhanced Radio Paging or ODA

sub Group13A {
  my @blocks = @_;

  return if (@blocks < 4);

  print_appdata ('Pager', sprintf('13A: %02x %04x %04x',
    extract_bits($blocks[1], 0, 5), $blocks[2], $blocks[3]));

}

# 14A: Enhanced Other Networks (EON) information

sub Group14A {
  my @blocks = @_;

  return if (@blocks < 4);

  $station{$pi}{'hasEON'}    = TRUE;
  my $eon_pi                 = $blocks[3];
  $station{$eon_pi}{'TP'}    = extract_bits($blocks[1], 4, 1);
  my $eon_variant            = extract_bits($blocks[1], 0, 4);
  utter ('  Other Network', ' ON:');
  utter ('    PI:     '.sprintf('%04X',$eon_pi).
    ((exists($station{$eon_pi}{'chname'})) &&
    " ($station{$eon_pi}{'chname'})"),
    sprintf("%04X[",$eon_pi));
  utter ('    TP:     '.$TP_descr[$station{$eon_pi}{'TP'}],
         'TP:'.$station{$eon_pi}{'TP'});

  given ($eon_variant) {

    when ([0..3]) {
      utter(q{  },q{});
      if (not exists($station{$eon_pi}{'PSbuf'})) {
        $station{$eon_pi}{'PSbuf'} = q{ } x 8;
      }
      set_PS_chars($eon_pi, $eon_variant*2, extract_bits($blocks[2], 8, 8),
        extract_bits($blocks[2], 0, 8));
    }

    when (4) {
      utter ('    AF:     '.parse_AF(TRUE, extract_bits($blocks[2], 8, 8)),
             ' AF:'.parse_AF(TRUE, extract_bits($blocks[2], 8, 8)));
      utter ('    AF:     '.parse_AF(TRUE, extract_bits($blocks[2], 0, 8)),
             ' AF:'.parse_AF(TRUE, extract_bits($blocks[2], 0, 8)));
    }

    when ([5..8]) {
      utter('    AF:     Tuned frequency '.
        parse_AF(TRUE, extract_bits($blocks[2], 8, 8)).' maps to '.
        parse_AF(TRUE, extract_bits($blocks[2], 0, 8)),' AF:map:'.
        parse_AF(TRUE, extract_bits($blocks[2], 8, 8)).'->'.
        parse_AF(TRUE, extract_bits($blocks[2], 0, 8)));
    }

    when (9) {
      utter ("    AF:     Tuned frequency ".
        parse_AF(TRUE, extract_bits($blocks[2], 8, 8))." maps to ".
        parse_AF(FALSE,extract_bits($blocks[2], 0, 8)),
        " AF:map:".parse_AF(TRUE, extract_bits($blocks[2], 8, 8))."->".
        parse_AF(FALSE,extract_bits($blocks[2], 0, 8)));
    }

    when (12) {
      $station{$eon_pi}{'LA'}  = extract_bits($blocks[2], 15,  1);
      $station{$eon_pi}{'EG'}  = extract_bits($blocks[2], 14,  1);
      $station{$eon_pi}{'ILS'} = extract_bits($blocks[2], 13,  1);
      $station{$eon_pi}{'LSN'} = extract_bits($blocks[2], 1,  12);
      if ($station{$eon_pi}{'LA'})  {
        utter ('    Link: Program is linked to linkage set '.
               sprintf('%03X', $station{$eon_pi}{'LSN'}),
               ' LSN:'.sprintf('%03X', $station{$eon_pi}{'LSN'}));
      }
      if ($station{$eon_pi}{'EG'})  {
        utter ('    Link: Program is member of an extended generic set',
          ' Link:EG');
      }
      if ($station{$eon_pi}{'ILS'}) {
        utter ('    Link: Program is linked internationally', 'Link:ILS');
      }
      # TODO: Country codes, pg. 51
    }

    when (13) {
      $station{$eon_pi}{'PTY'} = extract_bits($blocks[2], 11, 5);
      $station{$eon_pi}{'TA'}  = extract_bits($blocks[2],  0, 1);
      utter (("    PTY:    $station{$eon_pi}{'PTY'} ".
        (exists $station{$eon_pi}{'ECC'} &&
        ($countryISO[$station{$pi}{'ECC'}][$station{$eon_pi}{'CC'}] // q{})
        =~ /us|ca|mx/ ? $ptynamesUS[$station{$eon_pi}{'PTY'}] :
        $ptynames[$station{$eon_pi}{'PTY'}])),
        ' PTY:'.$station{$eon_pi}{'PTY'});
      utter ('    TA:     '.
        $TA_descr[$station{$eon_pi}{'TP'}][$station{$eon_pi}{'TA'}],
        ' TA:'.$station{$eon_pi}{'TA'});
    }

    when (14) {
      utter ('    PIN:    '. parse_PIN($blocks[2]),' PIN:'.parse_PIN($blocks[2]));
    }

    when (15) {
      utter ('    Broadcaster data: '.sprintf('%04x', $blocks[2]),
             ' BDATA:'.sprintf('%04x', $blocks[2]));
    }

    default {
      say "    EON variant $eon_variant is unallocated";
    }

  }
  utter(q{},']');
}

# 14B: Enhanced Other Networks (EON) information

sub Group14B {
  my @blocks = @_;

  return if (@blocks < 4);

  my $eon_pi              =  $blocks[3];
  $station{$eon_pi}{'TP'} = extract_bits($blocks[1], 4, 1);
  $station{$eon_pi}{'TA'} = extract_bits($blocks[1], 3, 1);
  utter ('  Other Network', ' ON:');
  utter ('    PI:     '.sprintf('%04X', $eon_pi).
    ((exists($station{$eon_pi}{'chname'})) &&
    " ($station{$eon_pi}{'chname'})"),
    sprintf('%04X[',$eon_pi));
  utter ('    TP:     '.
    $TP_descr[$station{$eon_pi}{'TP'}],
    'TP:'.$station{$eon_pi}{'TP'});
  utter ('    TA:     '.
    $TA_descr[$station{$eon_pi}{'TP'}][$station{$eon_pi}{'TA'}],
    'TA:'.$station{$eon_pi}{'TA'});
}

# 15B: Fast basic tuning and switching information

sub Group15B {
  my @blocks = @_;

  # DI
  my $DI_adr = 3 - extract_bits($blocks[1], 0, 2);
  my $DI     = extract_bits($blocks[1], 2, 1);
  parse_DI($DI_adr, $DI);

  # TA, M/S
  $station{$pi}{'TA'} = extract_bits($blocks[1], 4, 1);
  $station{$pi}{'MS'} = extract_bits($blocks[1], 3, 1);
  utter ('  TA:     '.$TA_descr[$station{$pi}{'TP'}][$station{$pi}{'TA'}],
         ' TA:'.$station{$pi}{'TA'});
  utter ('  M/S:    '.qw( Speech Music )[$station{$pi}{'MS'}],
         ' MS:'.qw(S M)[$station{$pi}{'MS'}]);
  $station{$pi}{'hasMS'} = TRUE;

}

# Any group used for Open Data

sub ODAGroup {

  my ($group_type, @blocks) = @_;

  return if (@blocks < 4);

  if (exists $station{$pi}{'ODAaid'}{$group_type}) {
    given ($station{$pi}{'ODAaid'}{$group_type}) {

      when ([0xCD46, 0xCD47]) {
        print_appdata ('TMC', sprintf('msg %02x %04x %04x',
          extract_bits($blocks[1], 0, 5), $blocks[2], $blocks[3]));
      }
      when (0x4BD7) {
        parse_RTp(@blocks);
      }
      when (0x6552) {
        parse_eRT(@blocks);
      }
      default {
        say sprintf('          Unimplemented ODA %04x: %02x %04x %04x',
          $station{$pi}{'ODAaid'}{$group_type},
          extract_bits($blocks[1], 0, 5), $blocks[2], $blocks[3]);
      }

    }
  } else {
    utter ('          Will need group 3A first to identify ODA', q{});
  }
}

sub screenReset {

  $station{$pi}{'RTbuf'} = (q{ } x 64) if (!exists $station{$pi}{'RTbuf'});
  $station{$pi}{'hasRT'} = FALSE       if (!exists $station{$pi}{'hasRT'});
  $station{$pi}{'hasMS'} = FALSE       if (!exists $station{$pi}{'hasMS'});
  $station{$pi}{'TP'}    = FALSE       if (!exists $station{$pi}{'TP'});
  $station{$pi}{'TA'}    = FALSE       if (!exists $station{$pi}{'TA'});

}

# Change characters in RadioText

sub set_rt_chars {
  (my $lok, my @a) = @_;

  $station{$pi}{'hasRT'} = TRUE;

  for my $i (0..$#a) {
    given ($a[$i]) {
      when (0x0D) {
        substr($station{$pi}{'RTbuf'}, $lok+$i, 1) = q{↵};
      }
      when (0x0A) {
        substr($station{$pi}{'RTbuf'}, $lok+$i, 1) = q{␊};
      }
      default {
        substr($station{$pi}{'RTbuf'}, $lok+$i, 1) = $char_table[$a[$i]];
      }
    }
    $station{$pi}{'RTrcvd'}[$lok+$i] = TRUE;
  }

  my $minRTlen = ($station{$pi}{'RTbuf'} =~ /↵/ ?
    index($station{$pi}{'RTbuf'}, q{↵}) + 1 :
    $station{$pi}{'presetminRTlen'} // 64);

  my $total_received
    = grep (defined $_, @{$station{$pi}{'RTrcvd'}}[0..$minRTlen]);
  $station{$pi}{'hasFullRT'} = ($total_received >= $minRTlen ? TRUE : FALSE);

  my $displayed_RT
    = ($is_interactive ? substr($station{$pi}{'RTbuf'},0,$lok).REVERSE.
                         substr($station{$pi}{'RTbuf'},$lok,scalar(@a)).RESET.
                         substr($station{$pi}{'RTbuf'},$lok+scalar(@a)) :
                         $station{$pi}{'RTbuf'});
  utter ('  RT:     '.$displayed_RT, q{ RT:'}.$displayed_RT.q{'});
  if ($station{$pi}{'hasFullRT'}) {
    utter (q{}, ' RTcomplete');
  }

  utter ('          '. join(q{}, (map ((defined) ? q{^} : q{ },
    @{$station{$pi}{'RTrcvd'}}[0..63]))), q{});
}

# Enhanced RadioText

sub parse_eRT {
  my $addr = extract_bits($_[1], 0, 5);

  if ($station{$pi}{'ert_chrtbl'} == 0x00 &&
     !$station{$pi}{'ert_isutf8'}         &&
      $station{$pi}{'ert_txtdir'} == 0) {

    for (0..1) {
      substr($station{$pi}{'eRTbuf'}, 2*$addr+$_, 1) = decode('UCS-2LE',
        chr(extract_bits($_[2+$_], 8, 8)).chr(extract_bits($_[2+$_], 0, 8)));
      $station{$pi}{'eRTrcvd'}[2*$addr+$_]           = TRUE;
    }

    say '  eRT:    '. substr($station{$pi}{'eRTbuf'},0,2*$addr).
                      ($is_interactive ? REVERSE : q{}).
                      substr($station{$pi}{'eRTbuf'},2*$addr,2).
                      ($is_interactive ? RESET : q{}).
                      substr($station{$pi}{'eRTbuf'},2*$addr+2);

    say '          '. join(q{}, (map ((defined) ? q{^} : q{ },
      @{$station{$pi}{'eRTrcvd'}}[0..63])));

  }
}

# Change characters in the Program Service name

sub set_PS_chars {
  my $pspi = $_[0];
  my $lok  = $_[1];
  my @khar = ($_[2], $_[3]);
  my $markup;

  if (not exists $station{$pspi}{'PSbuf'}) {
    $station{$pspi}{'PSbuf'} = q{ } x 8
  }

  substr($station{$pspi}{'PSbuf'}, $lok, 2)
    = $char_table[$khar[0]].$char_table[$khar[1]];

  # Display PS name when received without gaps

  if (not exists $station{$pspi}{'prevPSlok'}) {
    $station{$pspi}{'prevPSlok'} = 0;
  }
  if ($lok != $station{$pspi}{'prevPSlok'} + 2 ||
      $lok == $station{$pspi}{'prevPSlok'}) {
    $station{$pspi}{'PSrcvd'} = ();
  }
  $station{$pspi}{'PSrcvd'}[$lok/2] = TRUE;
  $station{$pspi}{'prevPSlok'}      = $lok;
  my $total_received
    = grep (defined, @{$station{$pspi}{'PSrcvd'}}[0..3]);

  if ($total_received == 4) {
    ($markup = $station{$pspi}{'PSbuf'}) =~ s/&/&amp;/g;
    $markup =~ s/</&lt;/g;
  }

  my $displayed_PS
    = ($is_interactive ? substr($station{$pspi}{'PSbuf'},0,$lok).REVERSE.
                         substr($station{$pspi}{'PSbuf'},$lok,2).RESET.
                         substr($station{$pspi}{'PSbuf'},$lok+2) :
                         $station{$pspi}{'PSbuf'});
  utter ('  PS:     '.$displayed_PS, q{ PS:'}.$displayed_PS.q{'});

}

# RadioText+

sub parse_RTp {

  my @ctype;
  my @start;
  my @len;

  # P.5.2
  my $itog  = extract_bits($_[1], 4, 1);
  my $irun  = extract_bits($_[1], 3, 1);
  $ctype[0] = (extract_bits($_[1], 0, 3) << 3) + extract_bits($_[2], 13, 3);
  $ctype[1] = (extract_bits($_[2], 0, 1) << 5) + extract_bits($_[3], 11, 5);
  $start[0] = extract_bits($_[2], 7, 6);
  $start[1] = extract_bits($_[3], 5, 6);
  $len[0]   = extract_bits($_[2], 1, 6);
  $len[1]   = extract_bits($_[3], 0, 5);

  say '  RadioText+: ';

  if ($irun) {
    say '    Item running';
    if ($station{$pi}{'rtp_which'} == 0) {
      for my $tag (0..1) {
        my $total_received
          = grep (defined $_,
          @{$station{$pi}{'RTrcvd'}}[$start[$tag]..($start[$tag] +
            $len[$tag] - 1)]);
        if ($total_received == $len[$tag]) {
          say '    Tag '.$rtpclass[$ctype[$tag]].': '.
            substr($station{$pi}{'RTbuf'}, $start[$tag], $len[$tag]);
        }
      }
    } else {
      # (eRT)
    }
  } else {
    say '    No item running';
  }

}

# Program Item Number

sub parse_PIN {
  my $d = extract_bits($_[0], 11, 5);
  return ($d ? sprintf('%02d@%02d:%02d', $d, extract_bits($_[0], 6, 5),
    extract_bits($_[0], 0, 6)) : 'None');
}

# Decoder Identification

sub parse_DI {
  given ($_[0]) {
    when (0) {
      utter ('  DI:     '. qw( Mono Stereo )[$_[1]],
             ' DI:'.qw( Mono Stereo )[$_[1]]);
    }
    when (1) {
      if ($_[1]) {
        utter ('  DI:     Artificial head', ' DI:ArtiHd');
      }
    }
    when (2) {
      if ($_[1]) {
        utter ('  DI:     Compressed', ' DI:Cmprsd');
      }
    }
    when (3) {
      utter ('  DI:     '. qw( Static Dynamic)[$_[1]] .' PTY',
             ' DI:'.qw( StaPTY DynPTY )[$_[1]]);
    }
  }
}

# Alternate Frequencies

sub parse_AF {
  my $is_fm = shift;
  my $num   = shift;
  my $af;
  if ($is_fm) {
    given ($num) {
      when ([1..204]) {
        $af = sprintf('%0.1fMHz', (87.5 + $num / 10) );
      }
      when (205) {
        $af = '(filler)';
      }
      when (224) {
        $af = q{"No AF exists"};
      }
      when ([225..249]) {
        $af = q{"}.($num == 225 ? '1 AF follows' :
          ($num - 224).' AFs follow').q{"};
      }
      when (250) {
        $af = q{"AM/LF freq follows"};
      }
      default {
        $af = '(error:$num)';
      }
    }
  } else {
    given ($num) {
      when ([1..15]) {
        $af = sprintf('%dkHz', 144 + $num * 9);
      }
      when ([16..135]) {
        $af = sprintf('%dkHz', 522 + ($num-15) * 9);
      }
      default {
        $af = 'N/A';
      }
    }
  }
  return $af;
}



sub init_data {

  # Program Type names
  @ptynames   = ('No PTY',           'News',             'Current Affairs',  'Information',
                 'Sport',            'Education',        'Drama',            'Cultures',
                 'Science',          'Varied Speech',    'Pop Music',        'Rock Music',
                 'Easy Listening',   'Light Classics M', 'Serious Classics', 'Other Music',
                 'Weather & Metr',   'Finance',          q{Children's Progs},'Social Affairs',
                 'Religion',         'Phone In',         'Travel & Touring', 'Leisure & Hobby',
                 'Jazz Music',       'Country Music',    'National Music',   'Oldies Music',
                 'Folk Music',       'Documentary',      'Alarm Test',       'Alarm - Alarm !');

  # PTY names for the US (RBDS)
  @ptynamesUS = ('No PTY',           'News',             'Information',      'Sports',
                 'Talk',             'Rock',             'Classic Rock',     'Adult Hits',
                 'Soft Rock',        'Top 40',           'Country',          'Oldies',
                 'Soft',             'Nostalgia',        'Jazz',             'Classical',
                 'Rhythm and Blues', 'Soft R & B',       'Foreign Language', 'Religious Music',
                 'Religious Talk',   'Personality',      'Public',           'College',
                 q{},                q{},                q{},                q{},
                 q{},                'Weather',          'Emergency Test',   'ALERT! ALERT!');

  # Basic LCD character set
  @char_table = split(//,
               q{                }.q{                }.q{ !"#¤%&'()*+,-./}.q{0123456789:;<=>?}.
               q{@ABCDEFGHIJKLMNO}.q{PQRSTUVWXYZ[\]―_}.q{‖abcdefghijklmno}.q[pqrstuvwxyz{|}¯ ].
               q{áàéèíìóòúùÑÇŞβ¡Ĳ}.q{âäêëîïôöûüñçşǧıĳ}.q{ªα©‰Ǧěňőπ€£$←↑→↓}.q{º¹²³±İńűµ¿÷°¼½¾§}.
               q{ÁÀÉÈÍÌÓÒÚÙŘČŠŽÐĿ}.q{ÂÄÊËÎÏÔÖÛÜřčšžđŀ}.q{ÃÅÆŒŷÝÕØÞŊŔĆŚŹŦð}.q{ãåæœŵýõøþŋŕćśźŧ });

  # Meanings of combinations of TP+TA
  @TP_descr = (  'Does not carry traffic announcements', 'Program carries traffic announcements' );
  @TA_descr = ( ['No EON with traffic announcements',    'EON specifies another program with traffic announcements'],
              ['No traffic announcement at present',   'A traffic announcement is currently being broadcast']);

  # Language names
  @langname = (
     'Unknown',      'Albanian',      'Breton',     'Catalan',    'Croatian',    'Welsh',     'Czech',      'Danish',
     'German',       'English',       'Spanish',    'Esperanto',  'Estonian',    'Basque',    'Faroese',    'French',
     'Frisian',      'Irish',         'Gaelic',     'Galician',   'Icelandic',   'Italian',   'Lappish',    'Latin',
     'Latvian',      'Luxembourgian', 'Lithuanian', 'Hungarian',  'Maltese',     'Dutch',     'Norwegian',  'Occitan',
     'Polish',       'Portuguese',    'Romanian',   'Romansh',    'Serbian',     'Slovak',    'Slovene',    'Finnish',
     'Swedish',      'Turkish',       'Flemish',    'Walloon',    q{},           q{},         q{},          q{},
     q{},            q{},             q{},          q{},          q{},           q{},         q{},          q{},
     q{},            q{},             q{},          q{},          q{},           q{},         q{},          q{},
     'Background',   q{},             q{},          q{},          q{},           'Zulu',      'Vietnamese', 'Uzbek',
     'Urdu',         'Ukrainian',     'Thai',       'Telugu',     'Tatar',       'Tamil',     'Tadzhik',    'Swahili',
     'Sranan Tongo', 'Somali',        'Sinhalese',  'Shona',      'Serbo-Croat', 'Ruthenian', 'Russian',    'Quechua',
     'Pushtu',       'Punjabi',       'Persian',    'Papamiento', 'Oriya',       'Nepali',    'Ndebele',    'Marathi',
     'Moldovian',    'Malaysian',     'Malagasay',  'Macedonian', 'Laotian',     'Korean',    'Khmer',      'Kazakh',
     'Kannada',      'Japanese',      'Indonesian', 'Hindi',      'Hebrew',      'Hausa',     'Gurani',     'Gujurati',
     'Greek',        'Georgian',      'Fulani',     'Dari',       'Churash',     'Chinese',   'Burmese',    'Bulgarian',
     'Bengali',      'Belorussian',   'Bambora',    'Azerbaijan', 'Assamese',    'Armenian',  'Arabic',     'Amharic' );

  # Open Data Applications
  %oda_app = (
     0x0000 => 'Normal features specified in Standard',            0x0093 => 'Cross referencing DAB within RDS',
     0x0BCB => 'Leisure & Practical Info for Drivers',             0x0C24 => 'ELECTRABEL-DSM 7',
     0x0CC1 => 'Wireless Playground broadcast control signal',     0x0D45 => 'RDS-TMC: ALERT-C / EN ISO 14819-1',
     0x0D8B => 'ELECTRABEL-DSM 18',                                0x0E2C => 'ELECTRABEL-DSM 3',
     0x0E31 => 'ELECTRABEL-DSM 13',                                0x0F87 => 'ELECTRABEL-DSM 2',
     0x125F => 'I-FM-RDS for fixed and mobile devices',            0x1BDA => 'ELECTRABEL-DSM 1',
     0x1C5E => 'ELECTRABEL-DSM 20',                                0x1C68 => 'ITIS In-vehicle data base',
     0x1CB1 => 'ELECTRABEL-DSM 10',                                0x1D47 => 'ELECTRABEL-DSM 4',
     0x1DC2 => 'CITIBUS 4',                                        0x1DC5 => 'Encrypted TTI using ALERT-Plus',
     0x1E8F => 'ELECTRABEL-DSM 17',                                0x4AA1 => 'RASANT',
     0x4AB7 => 'ELECTRABEL-DSM 9',                                 0x4BA2 => 'ELECTRABEL-DSM 5',
     0x4BD7 => 'RadioText+ (RT+)',                                 0x4C59 => 'CITIBUS 2',
     0x4D87 => 'Radio Commerce System (RCS)',                      0x4D95 => 'ELECTRABEL-DSM 16',
     0x4D9A => 'ELECTRABEL-DSM 11',                                0x5757 => 'Personal weather station',
     0x6552 => 'Enhanced RadioText (eRT)',                         0x7373 => 'Enhanced early warning system',
     0xC350 => 'NRSC Song Title and Artist',                       0xC3A1 => 'Personal Radio Service',
     0xC3B0 => 'iTunes Tagging',                                   0xC3C3 => 'NAVTEQ Traffic Plus',
     0xC4D4 => 'eEAS',                                             0xC549 => 'Smart Grid Broadcast Channel',
     0xC563 => 'ID Logic',                                         0xC737 => 'Utility Message Channel (UMC)',
     0xCB73 => 'CITIBUS 1',                                        0xCB97 => 'ELECTRABEL-DSM 14',
     0xCC21 => 'CITIBUS 3',                                        0xCD46 => 'RDS-TMC: ALERT-C / EN ISO 14819 parts 1, 2, 3, 6',
     0xCD47 => 'RDS-TMC: ALERT-C / EN ISO 14819 parts 1, 2, 3, 6', 0xCD9E => 'ELECTRABEL-DSM 8',
     0xCE6B => 'Encrypted TTI using ALERT-Plus',                   0xE123 => 'APS Gateway',
     0xE1C1 => 'Action code',                                      0xE319 => 'ELECTRABEL-DSM 12',
     0xE411 => 'Beacon downlink',                                  0xE440 => 'ELECTRABEL-DSM 15',
     0xE4A6 => 'ELECTRABEL-DSM 19',                                0xE5D7 => 'ELECTRABEL-DSM 6',
     0xE911 => 'EAS open protocol');

  # Country codes: @countryISO[ ECC ][ CC ] = ISO 3166-1 alpha 2
  @{$countryISO[0xA0]} = map { /__/ ? undef : $_ } qw( __ us us us us us us us us us us us __ us us __ );
  @{$countryISO[0xA1]} = map { /__/ ? undef : $_ } qw( __ __ __ __ __ __ __ __ __ __ __ ca ca ca ca gl );
  @{$countryISO[0xA2]} = map { /__/ ? undef : $_ } qw( __ ai ag ec fk bb bz ky cr cu ar br bm an gp bs );
  @{$countryISO[0xA3]} = map { /__/ ? undef : $_ } qw( __ bo co jm mq gf py ni __ pa dm do cl gd tc gy );
  @{$countryISO[0xA4]} = map { /__/ ? undef : $_ } qw( __ gt hn aw __ ms tt pe sr uy kn lc sv ht ve __ );
  @{$countryISO[0xA5]} = map { /__/ ? undef : $_ } qw( __ __ __ __ __ __ __ __ __ __ __ mx vc mx mx mx );
  @{$countryISO[0xA6]} = map { /__/ ? undef : $_ } qw( __ __ __ __ __ __ __ __ __ __ __ __ __ __ __ pm );

  @{$countryISO[0xD0]} = map { /__/ ? undef : $_ } qw( __ cm cf dj mg ml ao gq ga gn za bf cg tg bj mw );
  @{$countryISO[0xD1]} = map { /__/ ? undef : $_ } qw( __ na lr gh mr st cv sn gm bi __ bw km tz et bg );
  @{$countryISO[0xD2]} = map { /__/ ? undef : $_ } qw( __ sl zw mz ug sz ke so ne td gw zr ci tz zm __ );
  @{$countryISO[0xD3]} = map { /__/ ? undef : $_ } qw( __ __ __ eh __ rw ls __ sc __ mu __ sd __ __ __ );

  @{$countryISO[0xE0]} = map { /__/ ? undef : $_ } qw( __ de dz ad il it be ru ps al at hu mt de __ eg );
  @{$countryISO[0xE1]} = map { /__/ ? undef : $_ } qw( __ gr cy sm ch jo fi lu bg dk gi iq gb ly ro fr );
  @{$countryISO[0xE2]} = map { /__/ ? undef : $_ } qw( __ ma cz pl va sk sy tn __ li is mc lt yu es no );
  @{$countryISO[0xE3]} = map { /__/ ? undef : $_ } qw( __ ie ie tr mk tj __ __ nl lv lb az hr kz se by );
  @{$countryISO[0xE4]} = map { /__/ ? undef : $_ } qw( __ md ee kg __ __ ua __ pt si am uz ge __ tm ba );

  @{$countryISO[0xF0]} = map { /__/ ? undef : $_ } qw( __ au au au au au au au au sa af mm cn kp bh my );
  @{$countryISO[0xF1]} = map { /__/ ? undef : $_ } qw( __ ki bt bd pk fj om nr ir nz sb bn lk tw kr hk );
  @{$countryISO[0xF2]} = map { /__/ ? undef : $_ } qw( __ kw qa kh ws in mo vn ph jp sg mv id ae np vu );
  @{$countryISO[0xF3]} = map { /__/ ? undef : $_ } qw( __ la th to __ __ __ __ __ pg __ ye __ __ fm mn );

  # RadioText+ classes
  @rtpclass = ('dummy_class',          'item.title',                'item.album',           'item.tracknumber',
               'item.artist',          'item.composition',          'item.movement',        'item.conductor',
               'item.composer',        'item.band',                 'item.comment',         'item.genre',
               'info.news',            'info.news.local',           'info.stockmarket',     'info.sport',
               'info.lottery',         'info.horoscope',            'info.daily_diversion', 'info.health',
               'info.event',           'info.scene',                'info.cinema',          'info.tv',
               'info.date_time',       'info.weather',              'info.traffic',         'info.alarm',
               'info.advertisement',   'info.url',                  'info.other',           'stationname.short',
               'stationname.long',     'programme.now',             'programme.next',       'programme.part',
               'programme.host',       'programme.editorial_staff', 'programme.frequency',  'programme.homepage',
               'programme.subchannel', 'phone.hotline',             'phone.studio',         'phone.other',
               'sms.studio',           'sms.other',                 'email.hotline',        'email.studio',
               'email.other',          'mms.other',                 'chat',                 'chat.centre',
               'vote.question',        'vote.centre',               q{},                    q{},
               q{},                    q{},                         q{},                    'place',
               'appointment',          'identifier',                'purchase',             'get_data');

  # Group type descriptions
  @group_names = (
   'Basic tuning and switching information',      'Basic tuning and switching information',
   'Program Item Number and slow labeling codes', 'Program Item Number',
   'RadioText',                                   'RadioText',
   'Applications Identification for Open Data',   'Open Data Applications',
   'Clock-time and date',                         'Open Data Applications',
   'Transparent Data Channels or ODA',            'Transparent Data Channels or ODA',
   'In House applications or ODA',                'In House applications or ODA',
   'Radio Paging or ODA',                         'Open Data Applications',
   'Traffic Message Channel or ODA',              'Open Data Applications',
   'Emergency Warning System or ODA',             'Open Data Applications',
   'Program Type Name',                           'Open Data Applications',
   'Open Data Applications',                      'Open Data Applications',
   'Open Data Applications',                      'Open Data Applications',
   'Enhanced Radio Paging or ODA',                'Open Data Applications',
   'Enhanced Other Networks information',         'Enhanced Other Networks information',
   'Undefined',                                   'Fast switching information');

}


# Extract len bits from int, starting at nth bit from the right
# bits (int, n, len)
sub extract_bits {
  return (($_[0] >> $_[1]) & (2 ** $_[2] - 1));
}

sub print_appdata {
  my ($appname, $data) = @_;
  if (exists $options{t}) {
    my $timestamp = strftime('%Y-%m-%dT%H:%M:%S%z ', localtime);
    print $timestamp;
  }
  say "[app] $appname $data";
}

sub utter {
  my ($long, $short) = @_;
  if ($verbosity == 0) {
    if ($short =~ /\n/) {
      print $linebuf.$short;
      $linebuf = q{};
    } else {
      $linebuf .= $short;
    }
  } elsif ($verbosity == 1) {
    if ($long ne q{}) {
      print $long."\n";
    }
  }
}

sub log2 {
  return (log($_[0]) / log(2));
}
