# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2015 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

package RT::Interface::Email;

use strict;
use warnings;
use 5.010;

use Email::Address;
use MIME::Entity;
use RT::EmailParser;
use File::Temp;
use Mail::Mailer ();
use Text::ParseWords qw/shellwords/;
use RT::Util 'safe_run_child';
use File::Spec;
use MIME::Words ();
use Scope::Upper qw/unwind HERE/;

=head1 NAME

  RT::Interface::Email - helper functions for parsing email sent to RT

=head1 METHODS

=head2 RECEIVING MAIL

=head3 Gateway ARGSREF

Takes parameters:

    action
    queue
    message


This performs all the "guts" of the mail rt-mailgate program, and is
designed to be called from the web interface with a message, user
object, and so on.

Can also take an optional 'ticket' parameter; this ticket id overrides
any ticket id found in the subject.

Returns:

    An array of:

    (status code, message, optional ticket object)

    status code is a numeric value.

      for temporary failures, the status code should be -75

      for permanent failures which are handled by RT, the status code
      should be 0

      for succces, the status code should be 1

=cut

my $SCOPE;
sub TMPFAIL { unwind (-75,     $_[0], undef, => $SCOPE) }
sub FAILURE { unwind (  0,     $_[0], $_[1], => $SCOPE) }
sub SUCCESS { unwind (  1, "Success", $_[0], => $SCOPE) }


sub Gateway {
    my $argsref = shift;
    my %args    = (
        action  => 'correspond',
        queue   => '1',
        ticket  => undef,
        message => undef,
        %$argsref
    );

    # Set the scope to return from with TMPFAIL/FAILURE/SUCCESS
    $SCOPE = HERE;

    # Validate the action
    my ( $status, @actions ) = IsCorrectAction( $args{'action'} );
    TMPFAIL(
        "Invalid 'action' parameter "
            . $actions[0]
            . " for queue "
            . $args{'queue'},
    ) unless $status;

    my $parser = RT::EmailParser->new();
    $parser->SmartParseMIMEEntityFromScalar(
        Message => $args{'message'},
        Decode => 0,
        Exact => 1,
    );

    my $Message = $parser->Entity();
    unless ($Message) {
        MailError(
            Subject     => "RT Bounce: Unparseable message",
            Explanation => "RT couldn't process the message below",
            Attach      => $args{'message'}
        );

        FAILURE(
            "Failed to parse this message. Something is likely badly wrong with the message"
        );
    }

    my @mail_plugins = grep $_, RT->Config->Get('MailPlugins');
    push @mail_plugins, "Auth::MailFrom" unless @mail_plugins;
    @mail_plugins = _LoadPlugins( @mail_plugins );

    #Set up a queue object
    my $SystemQueueObj = RT::Queue->new( RT->SystemUser );
    $SystemQueueObj->Load( $args{'queue'} );

    foreach my $class ( grep !ref, @mail_plugins ) {
        # check if we should apply filter before decoding
        my $Code = $class->can("BeforeDecode");
        next unless $Code;
        $Code->(
            Message       => $Message,
            RawMessageRef => \$args{'message'},
            Queue         => $SystemQueueObj,
            Actions       => \@actions,
        );
    }

    $parser->_DecodeBodies;
    $parser->RescueOutlook;
    $parser->_PostProcessNewEntity;

    my $head = $Message->head;
    my $From = Encode::decode( "UTF-8", $head->get("From") );
    chomp $From if defined $From;

    my $MessageId = Encode::decode( "UTF-8", $head->get('Message-ID') )
        || "<no-message-id-". time . rand(2000) .'@'. RT->Config->Get('Organization') .'>';

    #Pull apart the subject line
    my $Subject = Encode::decode( "UTF-8", $head->get('Subject') || '');
    chomp $Subject;

    # Lets check for mail loops of various sorts.
    my $ErrorsTo = ParseErrorsToAddressFromHead( $head );
    $ErrorsTo = RT->Config->Get('OwnerEmail')
        if IsMachineGeneratedMail(
            Message   => $Message,
            ErrorsTo  => $ErrorsTo,
            Subject   => $Subject,
            MessageId => $MessageId,
        );

    $args{'ticket'} ||= ExtractTicketId( $Message );

    my $SystemTicket = RT::Ticket->new( RT->SystemUser );
    $SystemTicket->Load( $args{'ticket'} ) if ( $args{'ticket'} ) ;

    # We can safely have no queue of we have a known-good ticket
    TMPFAIL("RT couldn't find the queue: " . $args{'queue'})
        unless $SystemTicket->id || $SystemQueueObj->id;

    my $CurrentUser = GetCurrentUser(
        ErrorsTo      => $ErrorsTo,
        MailPlugins   => \@mail_plugins,
        Message       => $Message,
        RawMessageRef => \$args{message},
        Ticket        => $SystemTicket,
        Queue         => $SystemQueueObj,
    );

    # We only care about ACLs on the _first_ action, as later actions
    # may have gotten rights by the time they happen.
    CheckACL(
        Action        => $actions[0],
        ErrorsTo      => $ErrorsTo,
        MailPlugins   => \@mail_plugins,
        Message       => $Message,
        CurrentUser   => $CurrentUser,
        Ticket        => $SystemTicket,
        Queue         => $SystemQueueObj,
    );

    $head->replace('X-RT-Interface' => 'Email');

    # if plugin's updated SystemTicket then update arguments
    $args{'ticket'} = $SystemTicket->Id if $SystemTicket && $SystemTicket->Id;

    my $Ticket = RT::Ticket->new($CurrentUser);

    if ( !$args{'ticket'} && grep /^(comment|correspond)$/, @actions )
    {

        my @Cc;
        my @Requestors = ( $CurrentUser->id );

        if (RT->Config->Get('ParseNewMessageForTicketCcs')) {
            @Cc = ParseCcAddressesFromHead(
                Head        => $head,
                CurrentUser => $CurrentUser,
                QueueObj    => $SystemQueueObj
            );
        }

        # ExtractTicketId may have been overridden, and edited the Subject
        my $NewSubject = Encode::decode( "UTF-8", $head->get('Subject') );
        chomp $NewSubject;

        my ( $id, $Transaction, $ErrStr ) = $Ticket->Create(
            Queue     => $SystemQueueObj->Id,
            Subject   => $NewSubject,
            Requestor => \@Requestors,
            Cc        => \@Cc,
            MIMEObj   => $Message
        );
        if ( $id == 0 ) {
            MailError(
                To          => $ErrorsTo,
                Subject     => "Ticket creation failed: $Subject",
                Explanation => $ErrStr,
                MIMEObj     => $Message
            );
            FAILURE("Ticket creation From: $From failed: $ErrStr", $Ticket );
        }

        # strip comments&corresponds from the actions we don't need
        # to record them if we've created the ticket just now
        @actions = grep !/^(comment|correspond)$/, @actions;
        $args{'ticket'} = $id;

    } elsif ( $args{'ticket'} ) {

        $Ticket->Load( $args{'ticket'} );
        unless ( $Ticket->Id ) {
            my $error = "Could not find a ticket with id " . $args{'ticket'};
            MailError(
                To          => $ErrorsTo,
                Subject     => "Message not recorded: $Subject",
                Explanation => $error,
                MIMEObj     => $Message
            );

            FAILURE( $error );
        }
        $args{'ticket'} = $Ticket->id;
    } else {
        SUCCESS( $Ticket );
    }

    # }}}

    my $unsafe_actions = RT->Config->Get('UnsafeEmailCommands');
    foreach my $action (@actions) {

        #   If the action is comment, add a comment.
        if ( $action =~ /^(?:comment|correspond)$/i ) {
            my $method = ucfirst lc $action;
            my ( $status, $msg ) = $Ticket->$method( MIMEObj => $Message );
            unless ($status) {

                #Warn the sender that we couldn't actually submit the comment.
                MailError(
                    To          => $ErrorsTo,
                    Subject     => "Message not recorded ($method): $Subject",
                    Explanation => $msg,
                    MIMEObj     => $Message
                );
                FAILURE( "Message From: $From not recorded: $msg", $Ticket );
            }
        } elsif ($unsafe_actions) {
            _RunUnsafeAction(
                Action      => $action,
                ErrorsTo    => $ErrorsTo,
                Message     => $Message,
                Ticket      => $Ticket,
                CurrentUser => $CurrentUser,
            );
        }
    }
    SUCCESS( $Ticket );
}

=head3 IsCorrectAction

Returns a list of valid actions we've found for this message

=cut

sub IsCorrectAction {
    my $action = shift;
    my @actions = grep $_, split /-/, $action;
    return ( 0, '(no value)' ) unless @actions;
    foreach ( @actions ) {
        return ( 0, $_ ) unless /^(?:comment|correspond|take|resolve)$/;
    }
    return ( 1, @actions );
}

sub _LoadPlugins {
    my @mail_plugins = @_;

    my @res;
    foreach my $plugin (@mail_plugins) {
        if ( ref($plugin) eq "CODE" ) {
            push @res, $plugin;
        } elsif ( !ref $plugin ) {
            my $Class = $plugin;
            $Class = "RT::Interface::Email::" . $Class
                unless $Class =~ /^RT::/;
            $Class->require or
                do { $RT::Logger->error("Couldn't load $Class: $@"); next };

            unless ( $Class->DOES( "RT::Interface::Email::Role" ) ) {
                $RT::Logger->crit( "$Class does not implement RT::Interface::Email::Role.  Mail plugins from RT 4.2 and earlier are not forward-compatible with RT 4.4.");
                next;
            }
            push @res, $Class;
        } else {
            $RT::Logger->crit( "$plugin - is not class name or code reference");
        }
    }
    return @res;
}

=head3 GetCurrentUser

=cut

sub GetCurrentUser {
    my %args = (
        ErrorsTo      => undef,
        MailPlugins   => [],
        Message       => undef,
        RawMessageRef => undef,
        Ticket        => undef,
        Queue         => undef,
        @_,
    );

    # Since this needs loading, no matter what
    foreach (@{ $args{MailPlugins} }) {
        my $Code;
        if ( ref($_) eq "CODE" ) {
            $Code = $_;
        } else {
            $Code = $_->can("GetCurrentUser");
            next unless $Code;
        }

        my $CurrentUser = $Code->(
            Message       => $args{Message},
            RawMessageRef => $args{RawMessageRef},
            Ticket        => $args{Ticket},
            Queue         => $args{Queue},
        );
        return $CurrentUser if $CurrentUser and $CurrentUser->id;
    }

    # None of the GetCurrentUser plugins found a user.  This is
    # rare; some non-Auth::MailFrom authentication plugin which
    # doesn't always return a current user?
    MailError(
        To          => $args{ErrorsTo},
        Subject     => "Permission Denied",
        Explanation => "You do not have permission to communicate with RT",
        MIMEObj     => $args{Message},
    );
    FAILURE("Could not load a valid user");
}

=head2 CheckACL

    # Authentication Level
    # -1 - Get out.  this user has been explicitly declined
    # 0 - User may not do anything (Not used at the moment)
    # 1 - Normal user
    # 2 - User is allowed to specify status updates etc. a la enhanced-mailgate

=cut

sub CheckACL {
    my %args = (
        Action        => undef,
        ErrorsTo      => undef,
        MailPlugins   => [],
        Message       => undef,
        CurrentUser   => undef,
        Ticket        => undef,
        Queue         => undef,
        @_,
    );

    for my $class (@{ $args{MailPlugins} }) {
        my $Code = $class->can("CheckACL");
        next unless $Code;

        return if $Code->(
            ErrorsTo      => $args{ErrorsTo},
            Message       => $args{Message},
            CurrentUser   => $args{CurrentUser},
            Action        => $args{Action},
            Ticket        => $args{Ticket},
            Queue         => $args{Queue},
        );
    }

    # Nobody said yes, and nobody said FAILURE; fail closed
    MailError(
        To          => $args{ErrorsTo},
        Subject     => "Permission Denied",
        Explanation => "You have no permission to $args{Action}",
        MIMEObj     => $args{Message},
    );
    FAILURE( "You have no permission to $args{Action}" );
}

=head3 ParseCcAddressesFromHead HASH

Takes a hash containing QueueObj, Head and CurrentUser objects.
Returns a list of all email addresses in the To and Cc
headers b<except> the current Queue's email addresses, the CurrentUser's
email address  and anything that the configuration sub RT::IsRTAddress matches.

=cut

sub ParseCcAddressesFromHead {
    my %args = (
        Head        => undef,
        QueueObj    => undef,
        CurrentUser => undef,
        @_
    );

    my $current_address = lc $args{'CurrentUser'}->EmailAddress;
    my $user = $args{'CurrentUser'}->UserObj;

    return
        grep $_ ne $current_address && !RT::EmailParser->IsRTAddress( $_ ),
        map lc $user->CanonicalizeEmailAddress( $_->address ),
        map RT::EmailParser->CleanupAddresses( Email::Address->parse(
              Encode::decode( "UTF-8", $args{'Head'}->get( $_ ) ) ) ),
        qw(To Cc);
}



=head3 ParseSenderAddressFromHead HEAD

Takes a MIME::Header object. Returns (user@host, friendly name, errors)
where the first two values are the From (evaluated in order of
Reply-To:, From:, Sender).

A list of error messages may be returned even when a Sender value is
found, since it could be a parse error for another (checked earlier)
sender field. In this case, the errors aren't fatal, but may be useful
to investigate the parse failure.

=cut

sub ParseSenderAddressFromHead {
    my $head = shift;
    my @sender_headers = ('Reply-To', 'From', 'Sender');
    my @errors;  # Accumulate any errors

    #Figure out who's sending this message.
    foreach my $header ( @sender_headers ) {
        my $addr_line = Encode::decode( "UTF-8", $head->get($header) ) || next;
        my ($addr, $name) = ParseAddressFromHeader( $addr_line );
        # only return if the address is not empty
        return ($addr, $name, @errors) if $addr;

        chomp $addr_line;
        push @errors, "$header: $addr_line";
    }

    return (undef, undef, @errors);
}

=head3 ParseErrorsToAddressFromHead HEAD

Takes a MIME::Header object. Return a single value : user@host
of the From (evaluated in order of Return-path:,Errors-To:,Reply-To:,
From:, Sender)

=cut

sub ParseErrorsToAddressFromHead {
    my $head = shift;

    #Figure out who's sending this message.

    foreach my $header ( 'Errors-To', 'Reply-To', 'From', 'Sender' ) {

        # If there's a header of that name
        my $headerobj = Encode::decode( "UTF-8", $head->get($header) );
        if ($headerobj) {
            my ( $addr, $name ) = ParseAddressFromHeader($headerobj);

            # If it's got actual useful content...
            return ($addr) if ($addr);
        }
    }
}



=head3 ParseAddressFromHeader ADDRESS

Takes an address from C<$head->get('Line')> and returns a tuple: user@host, friendly name

=cut

sub ParseAddressFromHeader {
    my $Addr = shift;

    # Some broken mailers send:  ""Vincent, Jesse"" <jesse@fsck.com>. Hate
    $Addr =~ s/\"\"(.*?)\"\"/\"$1\"/g;
    my @Addresses = RT::EmailParser->ParseEmailAddress($Addr);

    my ($AddrObj) = grep ref $_, @Addresses;
    unless ( $AddrObj ) {
        return ( undef, undef );
    }

    return ( $AddrObj->address, $AddrObj->phrase );
}

=head3 _HandleMachineGeneratedMail

Takes named params:
    Message
    ErrorsTo
    Subject

Checks the message to see if it's a bounce, if it looks like a loop, if it's autogenerated, etc.
Returns a triple of ("Should we continue (boolean)", "New value for $ErrorsTo", "Status message",
"This message appears to be a loop (boolean)" );

=cut

sub IsMachineGeneratedMail {
    my %args = (
        Message => undef,
        Subject => undef,
        MessageId => undef,
        @_
    );
    my $head = $args{'Message'}->head;

    my $IsBounce = CheckForBounce($head);
    my $IsAutoGenerated = CheckForAutoGenerated($head);
    my $IsSuspiciousSender = CheckForSuspiciousSender($head);
    my $IsALoop = CheckForLoops($head);

    my $owner_mail = RT->Config->Get('OwnerEmail');

    # Don't let the user stuff the RT-Squelch-Replies-To header.
    $head->delete('RT-Squelch-Replies-To');

    # If the message is autogenerated, we need to know, so we can not
    # send mail to the sender
    return unless $IsBounce || $IsSuspiciousSender || $IsAutoGenerated || $IsALoop;

    # Warn someone if it's a loop, before we drop it on the ground
    if ($IsALoop) {
        $RT::Logger->crit("RT Received mail (".$args{MessageId}.") from itself.");

        #Should we mail it to RTOwner?
        if ( RT->Config->Get('LoopsToRTOwner') ) {
            MailError(
                To          => $owner_mail,
                Subject     => "RT Bounce: ".$args{'Subject'},
                Explanation => "RT thinks this message may be a bounce",
                MIMEObj     => $args{Message}
            );
        }

        #Do we actually want to store it?
        FAILURE( "Message is a bounce" ) unless RT->Config->Get('StoreLoops');
    }

    # Squelch replies to the sender, and also leave a clue to
    # allow us to squelch ALL outbound messages. This way we
    # can punt the logic of "what to do when we get a bounce"
    # to the scrip. We might want to notify nobody. Or just
    # the RT Owner. Or maybe all Privileged watchers.
    my ( $Sender, $junk ) = ParseSenderAddressFromHead($head);
    $head->replace( 'RT-Squelch-Replies-To',    Encode::encode("UTF-8", $Sender ) );
    $head->replace( 'RT-DetectedAutoGenerated', 'true' );

    return 1;
}

=head3 CheckForLoops HEAD

Takes a HEAD object of L<MIME::Head> class and returns true if the
message's been sent by this RT instance. Uses "X-RT-Loop-Prevention"
field of the head for test.

=cut

sub CheckForLoops {
    my $head = shift;

    # If this instance of RT sent it our, we don't want to take it in
    my $RTLoop = Encode::decode( "UTF-8", $head->get("X-RT-Loop-Prevention") || "" );
    chomp ($RTLoop); # remove that newline
    if ( $RTLoop eq RT->Config->Get('rtname') ) {
        return 1;
    }

    # TODO: We might not trap the case where RT instance A sends a mail
    # to RT instance B which sends a mail to ...
    return undef;
}

=head3 CheckForSuspiciousSender HEAD

Takes a HEAD object of L<MIME::Head> class and returns true if sender
is suspicious. Suspicious means mailer daemon.

See also L</ParseSenderAddressFromHead>.

=cut

sub CheckForSuspiciousSender {
    my $head = shift;

    #if it's from a postmaster or mailer daemon, it's likely a bounce.

    #TODO: better algorithms needed here - there is no standards for
    #bounces, so it's very difficult to separate them from anything
    #else.  At the other hand, the Return-To address is only ment to be
    #used as an error channel, we might want to put up a separate
    #Return-To address which is treated differently.

    #TODO: search through the whole email and find the right Ticket ID.

    my ( $From, $junk ) = ParseSenderAddressFromHead($head);

    # If unparseable (non-ASCII), $From can come back undef
    return undef if not defined $From;

    if (   ( $From =~ /^mailer-daemon\@/i )
        or ( $From =~ /^postmaster\@/i )
        or ( $From eq "" ))
    {
        return (1);

    }

    return undef;
}

=head3 CheckForAutoGenerated HEAD

Takes a HEAD object of L<MIME::Head> class and returns true if message is
autogenerated. Checks C<Precedence>, C<Auto-Submitted>, and
C<X-FC-Machinegenerated> fields of the head in tests.

=cut

sub CheckForAutoGenerated {
    my $head = shift;

    if (grep { /^(bulk|junk)/i } $head->get_all("Precedence")) {
        return (1);
    }

    # Per RFC3834, any Auto-Submitted header which is not "no" means
    # it is auto-generated.
    my $AutoSubmitted = $head->get("Auto-Submitted") || "";
    if ( length $AutoSubmitted and $AutoSubmitted ne "no" ) {
        return (1);
    }

    # First Class mailer uses this as a clue.
    my $FCJunk = $head->get("X-FC-Machinegenerated") || "";
    if ( $FCJunk =~ /^true/i ) {
        return (1);
    }

    return (0);
}


sub CheckForBounce {
    my $head = shift;

    my $ReturnPath = $head->get("Return-path") || "";
    return ( $ReturnPath =~ /<>/ );
}

=head2 ExtractTicketId

Passed a MIME::Entity.  Returns a ticket id or undef to signal 'new ticket'.

This is a great entry point if you need to customize how ticket ids are
handled for your site. RT-Extension-RepliesToResolved demonstrates one
possible use for this extension.

If the Subject of this ticket is modified, it will be reloaded by the
mail gateway code before Ticket creation.

=cut

sub ExtractTicketId {
    my $entity = shift;

    my $subject = Encode::decode( "UTF-8", $entity->head->get('Subject') || '' );
    chomp $subject;
    return ParseTicketId( $subject );
}

=head2 ParseTicketId

Takes a string and searches for [subjecttag #id]

Returns the id if a match is found.  Otherwise returns undef.

=cut

sub ParseTicketId {
    my $Subject = shift;

    my $rtname = RT->Config->Get('rtname');
    my $test_name = RT->Config->Get('EmailSubjectTagRegex') || qr/\Q$rtname\E/i;

    # We use @captures and pull out the last capture value to guard against
    # someone using (...) instead of (?:...) in $EmailSubjectTagRegex.
    my $id;
    if ( my @captures = $Subject =~ /\[$test_name\s+\#(\d+)\s*\]/i ) {
        $id = $captures[-1];
    } else {
        foreach my $tag ( RT->System->SubjectTag ) {
            next unless my @captures = $Subject =~ /\[\Q$tag\E\s+\#(\d+)\s*\]/i;
            $id = $captures[-1];
            last;
        }
    }
    return undef unless $id;

    $RT::Logger->debug("Found a ticket ID. It's $id");
    return $id;
}

sub _RunUnsafeAction {
    my %args = (
        Action      => undef,
        ErrorsTo    => undef,
        Message     => undef,
        Ticket      => undef,
        CurrentUser => undef,
        @_
    );

    my $From = Encode::decode( "UTF-8", $args{Message}->head->get("From") );

    if ( $args{'Action'} =~ /^take$/i ) {
        my ( $status, $msg ) = $args{'Ticket'}->SetOwner( $args{'CurrentUser'}->id );
        unless ($status) {
            MailError(
                To          => $args{'ErrorsTo'},
                Subject     => "Ticket not taken",
                Explanation => $msg,
                MIMEObj     => $args{'Message'}
            );
            FAILURE( "Ticket not taken, by email From: $From" );
        }
    } elsif ( $args{'Action'} =~ /^resolve$/i ) {
        my $new_status = $args{'Ticket'}->FirstInactiveStatus;
        if ($new_status) {
            my ( $status, $msg ) = $args{'Ticket'}->SetStatus($new_status);
            unless ($status) {

                #Warn the sender that we couldn't actually submit the comment.
                MailError(
                    To          => $args{'ErrorsTo'},
                    Subject     => "Ticket not resolved",
                    Explanation => $msg,
                    MIMEObj     => $args{'Message'}
                );
                FAILURE( "Ticket not resolved, by email From: $From" );
            }
        }
    } else {
        FAILURE( "Not supported unsafe action $args{'Action'}, by email From: $From", $args{'Ticket'} );
    }
}

=head3 MailError PARAM HASH

Sends an error message. Takes a param hash:

=over 4

=item From - sender's address, by default is 'CorrespondAddress';

=item To - recipient, by default is 'OwnerEmail';

=item Bcc - optional Bcc recipients;

=item Subject - subject of the message, default is 'There has been an error';

=item Explanation - main content of the error, default value is 'Unexplained error';

=item MIMEObj - optional MIME entity that's attached to the error mail, as well we
add 'In-Reply-To' field to the error that points to this message.

=item Attach - optional text that attached to the error as 'message/rfc822' part.

=item LogLevel - log level under which we should write the subject and
explanation message into the log, by default we log it as critical.

=back

=cut

sub MailError {
    my %args = (
        To          => RT->Config->Get('OwnerEmail'),
        Bcc         => undef,
        From        => RT->Config->Get('CorrespondAddress'),
        Subject     => 'There has been an error',
        Explanation => 'Unexplained error',
        MIMEObj     => undef,
        Attach      => undef,
        LogLevel    => 'crit',
        @_
    );

    $RT::Logger->log(
        level   => $args{'LogLevel'},
        message => "$args{Subject}: $args{'Explanation'}",
    ) if $args{'LogLevel'};

    # the colons are necessary to make ->build include non-standard headers
    my %entity_args = (
        Type                    => "multipart/mixed",
        From                    => Encode::encode( "UTF-8", $args{'From'} ),
        Bcc                     => Encode::encode( "UTF-8", $args{'Bcc'} ),
        To                      => Encode::encode( "UTF-8", $args{'To'} ),
        Subject                 => EncodeToMIME( String => $args{'Subject'} ),
        'X-RT-Loop-Prevention:' => Encode::encode( "UTF-8", RT->Config->Get('rtname') ),
    );

    # only set precedence if the sysadmin wants us to
    if (defined(RT->Config->Get('DefaultErrorMailPrecedence'))) {
        $entity_args{'Precedence:'} =
            Encode::encode( "UTF-8", RT->Config->Get('DefaultErrorMailPrecedence') );
    }

    my $entity = MIME::Entity->build(%entity_args);
    SetInReplyTo( Message => $entity, InReplyTo => $args{'MIMEObj'} );

    $entity->attach(
        Type    => "text/plain",
        Charset => "UTF-8",
        Data    => Encode::encode( "UTF-8", $args{'Explanation'} . "\n" ),
    );

    if ( $args{'MIMEObj'} ) {
        $args{'MIMEObj'}->sync_headers;
        $entity->add_part( $args{'MIMEObj'} );
    }

    if ( $args{'Attach'} ) {
        $entity->attach( Data => Encode::encode( "UTF-8", $args{'Attach'} ), Type => 'message/rfc822' );

    }

    SendEmail( Entity => $entity, Bounce => 1 );
}

=head2 SENDING EMAIL

=head3 SendEmail Entity => undef, [ Bounce => 0, Ticket => undef, Transaction => undef ]

Sends an email (passed as a L<MIME::Entity> object C<ENTITY>) using
RT's outgoing mail configuration. If C<BOUNCE> is passed, and is a
true value, the message will be marked as an autogenerated error, if
possible. Sets Date field of the head to now if it's not set.

If the C<X-RT-Squelch> header is set to any true value, the mail will
not be sent. One use is to let extensions easily cancel outgoing mail.

Ticket and Transaction arguments are optional. If Transaction is
specified and Ticket is not then ticket of the transaction is
used, but only if the transaction belongs to a ticket.

Returns 1 on success, 0 on error or -1 if message has no recipients
and hasn't been sent.

=head3 Signing and Encrypting

This function as well signs and/or encrypts the message according to
headers of a transaction's attachment or properties of a ticket's queue.
To get full access to the configuration Ticket and/or Transaction
arguments must be provided, but you can force behaviour using Sign
and/or Encrypt arguments.

The following precedence of arguments are used to figure out if
the message should be encrypted and/or signed:

* if Sign or Encrypt argument is defined then its value is used

* else if Transaction's first attachment has X-RT-Sign or X-RT-Encrypt
header field then it's value is used

* else properties of a queue of the Ticket are used.

=cut

sub SendEmail {
    my (%args) = (
        Entity => undef,
        Bounce => 0,
        Ticket => undef,
        Transaction => undef,
        @_,
    );

    my $TicketObj = $args{'Ticket'};
    my $TransactionObj = $args{'Transaction'};

    unless ( $args{'Entity'} ) {
        $RT::Logger->crit( "Could not send mail without 'Entity' object" );
        return 0;
    }

    my $msgid = Encode::decode( "UTF-8", $args{'Entity'}->head->get('Message-ID') || '' );
    chomp $msgid;
    
    # If we don't have any recipients to send to, don't send a message;
    unless ( $args{'Entity'}->head->get('To')
        || $args{'Entity'}->head->get('Cc')
        || $args{'Entity'}->head->get('Bcc') )
    {
        $RT::Logger->info( $msgid . " No recipients found. Not sending." );
        return -1;
    }

    if ($args{'Entity'}->head->get('X-RT-Squelch')) {
        $RT::Logger->info( $msgid . " Squelch header found. Not sending." );
        return -1;
    }

    if (my $precedence = RT->Config->Get('DefaultMailPrecedence')
        and !$args{'Entity'}->head->get("Precedence")
    ) {
        $args{'Entity'}->head->replace( 'Precedence', Encode::encode("UTF-8",$precedence) );
    }

    if ( $TransactionObj && !$TicketObj
        && $TransactionObj->ObjectType eq 'RT::Ticket' )
    {
        $TicketObj = $TransactionObj->Object;
    }

    my $head = $args{'Entity'}->head;
    unless ( $head->get('Date') ) {
        require RT::Date;
        my $date = RT::Date->new( RT->SystemUser );
        $date->SetToNow;
        $head->replace( 'Date', Encode::encode("UTF-8",$date->RFC2822( Timezone => 'server' ) ) );
    }
    unless ( $head->get('MIME-Version') ) {
        # We should never have to set the MIME-Version header
        $head->replace( 'MIME-Version', '1.0' );
    }
    unless ( $head->get('Content-Transfer-Encoding') ) {
        # fsck.com #5959: Since RT sends 8bit mail, we should say so.
        $head->replace( 'Content-Transfer-Encoding', '8bit' );
    }

    if ( RT->Config->Get('Crypt')->{'Enable'} ) {
        %args = WillSignEncrypt(
            %args,
            Attachment => $TransactionObj ? $TransactionObj->Attachments->First : undef,
            Ticket     => $TicketObj,
        );
        my $res = SignEncrypt( %args );
        return $res unless $res > 0;
    }

    my $mail_command = RT->Config->Get('MailCommand');

    # if it is a sub routine, we just return it;
    return $mail_command->($args{'Entity'}) if UNIVERSAL::isa( $mail_command, 'CODE' );

    if ( $mail_command eq 'sendmailpipe' ) {
        my $path = RT->Config->Get('SendmailPath');
        my @args = shellwords(RT->Config->Get('SendmailArguments'));
        push @args, "-t" unless grep {$_ eq "-t"} @args;

        # SetOutgoingMailFrom and bounces conflict, since they both want -f
        if ( $args{'Bounce'} ) {
            push @args, shellwords(RT->Config->Get('SendmailBounceArguments'));
        } elsif ( my $MailFrom = RT->Config->Get('SetOutgoingMailFrom') ) {
            my $OutgoingMailAddress = $MailFrom =~ /\@/ ? $MailFrom : undef;
            my $Overrides = RT->Config->Get('OverrideOutgoingMailFrom') || {};

            if ($TicketObj) {
                my $Queue = $TicketObj->QueueObj;
                my $QueueAddressOverride = $Overrides->{$Queue->id}
                    || $Overrides->{$Queue->Name};

                if ($QueueAddressOverride) {
                    $OutgoingMailAddress = $QueueAddressOverride;
                } else {
                    $OutgoingMailAddress ||= $Queue->CorrespondAddress
                        || RT->Config->Get('CorrespondAddress');
                }
            }
            elsif ($Overrides->{'Default'}) {
                $OutgoingMailAddress = $Overrides->{'Default'};
            }

            push @args, "-f", $OutgoingMailAddress
                if $OutgoingMailAddress;
        }

        # VERP
        if ( $TransactionObj and
             my $prefix = RT->Config->Get('VERPPrefix') and
             my $domain = RT->Config->Get('VERPDomain') )
        {
            my $from = $TransactionObj->CreatorObj->EmailAddress;
            $from =~ s/@/=/g;
            $from =~ s/\s//g;
            push @args, "-f", "$prefix$from\@$domain";
        }

        eval {
            # don't ignore CHLD signal to get proper exit code
            local $SIG{'CHLD'} = 'DEFAULT';

            # if something wrong with $mail->print we will get PIPE signal, handle it
            local $SIG{'PIPE'} = sub { die "program unexpectedly closed pipe" };

            require IPC::Open2;
            my ($mail, $stdout);
            my $pid = IPC::Open2::open2( $stdout, $mail, $path, @args )
                or die "couldn't execute program: $!";

            $args{'Entity'}->print($mail);
            close $mail or die "close pipe failed: $!";

            waitpid($pid, 0);
            if ($?) {
                # sendmail exit statuses mostly errors with data not software
                # TODO: status parsing: core dump, exit on signal or EX_*
                my $msg = "$msgid: `$path @args` exited with code ". ($?>>8);
                $msg = ", interrupted by signal ". ($?&127) if $?&127;
                $RT::Logger->error( $msg );
                die $msg;
            }
        };
        if ( $@ ) {
            $RT::Logger->crit( "$msgid: Could not send mail with command `$path @args`: " . $@ );
            if ( $TicketObj ) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }
    }
    else {
        local ($ENV{'MAILADDRESS'}, $ENV{'PERL_MAILERS'});

        my @mailer_args = ($mail_command);
        if ( $mail_command eq 'sendmail' ) {
            $ENV{'PERL_MAILERS'} = RT->Config->Get('SendmailPath');
            push @mailer_args, grep {$_ ne "-t"}
                split(/\s+/, RT->Config->Get('SendmailArguments'));
        } elsif ( $mail_command eq 'testfile' ) {
            unless ($Mail::Mailer::testfile::config{outfile}) {
                $Mail::Mailer::testfile::config{outfile} = File::Temp->new;
                $RT::Logger->info("Storing outgoing emails in $Mail::Mailer::testfile::config{outfile}");
            }
        } else {
            push @mailer_args, RT->Config->Get('MailParams');
        }

        unless ( $args{'Entity'}->send( @mailer_args ) ) {
            $RT::Logger->crit( "$msgid: Could not send mail." );
            if ( $TicketObj ) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }
    }
    return 1;
}

=head3 PrepareEmailUsingTemplate Template => '', Arguments => {}

Loads a template. Parses it using arguments if it's not empty.
Returns a tuple (L<RT::Template> object, error message).

Note that even if a template object is returned MIMEObj method
may return undef for empty templates.

=cut

sub PrepareEmailUsingTemplate {
    my %args = (
        Template => '',
        Arguments => {},
        @_
    );

    my $template = RT::Template->new( RT->SystemUser );
    $template->LoadGlobalTemplate( $args{'Template'} );
    unless ( $template->id ) {
        return (undef, "Couldn't load template '". $args{'Template'} ."'");
    }
    return $template if $template->IsEmpty;

    my ($status, $msg) = $template->Parse( %{ $args{'Arguments'} } );
    return (undef, $msg) unless $status;

    return $template;
}

=head3 SendEmailUsingTemplate Template => '', Arguments => {}, From => CorrespondAddress, To => '', Cc => '', Bcc => ''

Sends email using a template, takes name of template, arguments for it and recipients.

=cut

sub SendEmailUsingTemplate {
    my %args = (
        Template => '',
        Arguments => {},
        To => undef,
        Cc => undef,
        Bcc => undef,
        From => RT->Config->Get('CorrespondAddress'),
        InReplyTo => undef,
        ExtraHeaders => {},
        @_
    );

    my ($template, $msg) = PrepareEmailUsingTemplate( %args );
    return (0, $msg) unless $template;

    my $mail = $template->MIMEObj;
    unless ( $mail ) {
        $RT::Logger->info("Message is not sent as template #". $template->id ." is empty");
        return -1;
    }

    $mail->head->replace( $_ => Encode::encode( "UTF-8", $args{ $_ } ) )
        foreach grep defined $args{$_}, qw(To Cc Bcc From);

    $mail->head->replace( $_ => Encode::encode( "UTF-8", $args{ExtraHeaders}{$_} ) )
        foreach keys %{ $args{ExtraHeaders} };

    SetInReplyTo( Message => $mail, InReplyTo => $args{'InReplyTo'} );

    return SendEmail( Entity => $mail );
}

=head3 GetForwardFrom Ticket => undef, Transaction => undef

Resolve the From field to use in forward mail

=cut

sub GetForwardFrom {
    my %args   = ( Ticket => undef, Transaction => undef, @_ );
    my $txn    = $args{Transaction};
    my $ticket = $args{Ticket} || $txn->Object;

    if ( RT->Config->Get('ForwardFromUser') ) {
        return ( $txn || $ticket )->CurrentUser->EmailAddress;
    }
    else {
        return $ticket->QueueObj->CorrespondAddress
          || RT->Config->Get('CorrespondAddress');
    }
}

=head3 GetForwardAttachments Ticket => undef, Transaction => undef

Resolve the Attachments to forward

=cut

sub GetForwardAttachments {
    my %args   = ( Ticket => undef, Transaction => undef, @_ );
    my $txn    = $args{Transaction};
    my $ticket = $args{Ticket} || $txn->Object;

    my $attachments = RT::Attachments->new( $ticket->CurrentUser );
    if ($txn) {
        $attachments->Limit( FIELD => 'TransactionId', VALUE => $txn->id );
    }
    else {
        $attachments->LimitByTicket( $ticket->id );
        $attachments->Limit(
            ALIAS         => $attachments->TransactionAlias,
            FIELD         => 'Type',
            OPERATOR      => 'IN',
            VALUE         => [ qw(Create Correspond) ],
        );
    }
    return $attachments;
}

sub WillSignEncrypt {
    my %args = @_;
    my $attachment = delete $args{Attachment};
    my $ticket     = delete $args{Ticket};

    if ( not RT->Config->Get('Crypt')->{'Enable'} ) {
        $args{Sign} = $args{Encrypt} = 0;
        return wantarray ? %args : 0;
    }

    for my $argument ( qw(Sign Encrypt) ) {
        next if defined $args{ $argument };

        if ( $attachment and defined $attachment->GetHeader("X-RT-$argument") ) {
            $args{$argument} = $attachment->GetHeader("X-RT-$argument");
        } elsif ( $ticket and $argument eq "Encrypt" ) {
            $args{Encrypt} = $ticket->QueueObj->Encrypt();
        } elsif ( $ticket and $argument eq "Sign" ) {
            # Note that $queue->Sign is UI-only, and that all
            # UI-generated messages explicitly set the X-RT-Crypt header
            # to 0 or 1; thus this path is only taken for messages
            # generated _not_ via the web UI.
            $args{Sign} = $ticket->QueueObj->SignAuto();
        }
    }

    return wantarray ? %args : ($args{Sign} || $args{Encrypt});
}

=head3 SignEncrypt Entity => undef, Sign => 0, Encrypt => 0

Signs and encrypts message using L<RT::Crypt>, but as well handle errors
with users' keys.

If a recipient has no key or has other problems with it, then the
unction sends a error to him using 'Error: public key' template.
Also, notifies RT's owner using template 'Error to RT owner: public key'
to inform that there are problems with users' keys. Then we filter
all bad recipients and retry.

Returns 1 on success, 0 on error and -1 if all recipients are bad and
had been filtered out.

=cut

sub SignEncrypt {
    my %args = (
        Entity => undef,
        Sign => 0,
        Encrypt => 0,
        @_
    );
    return 1 unless $args{'Sign'} || $args{'Encrypt'};

    my $msgid = Encode::decode( "UTF-8", $args{'Entity'}->head->get('Message-ID') || '' );
    chomp $msgid;

    $RT::Logger->debug("$msgid Signing message") if $args{'Sign'};
    $RT::Logger->debug("$msgid Encrypting message") if $args{'Encrypt'};

    my %res = RT::Crypt->SignEncrypt( %args );
    return 1 unless $res{'exit_code'};

    my @status = RT::Crypt->ParseStatus(
        Protocol => $res{'Protocol'}, Status => $res{'status'},
    );

    my @bad_recipients;
    foreach my $line ( @status ) {
        # if the passphrase fails, either you have a bad passphrase
        # or gpg-agent has died.  That should get caught in Create and
        # Update, but at least throw an error here
        if (($line->{'Operation'}||'') eq 'PassphraseCheck'
            && $line->{'Status'} =~ /^(?:BAD|MISSING)$/ ) {
            $RT::Logger->error( "$line->{'Status'} PASSPHRASE: $line->{'Message'}" );
            return 0;
        }
        next unless ($line->{'Operation'}||'') eq 'RecipientsCheck';
        next if $line->{'Status'} eq 'DONE';
        $RT::Logger->error( $line->{'Message'} );
        push @bad_recipients, $line;
    }
    return 0 unless @bad_recipients;

    $_->{'AddressObj'} = (Email::Address->parse( $_->{'Recipient'} ))[0]
        foreach @bad_recipients;

    foreach my $recipient ( @bad_recipients ) {
        my $status = SendEmailUsingTemplate(
            To        => $recipient->{'AddressObj'}->address,
            Template  => 'Error: public key',
            Arguments => {
                %$recipient,
                TicketObj      => $args{'Ticket'},
                TransactionObj => $args{'Transaction'},
            },
        );
        unless ( $status ) {
            $RT::Logger->error("Couldn't send 'Error: public key'");
        }
    }

    my $status = SendEmailUsingTemplate(
        To        => RT->Config->Get('OwnerEmail'),
        Template  => 'Error to RT owner: public key',
        Arguments => {
            BadRecipients  => \@bad_recipients,
            TicketObj      => $args{'Ticket'},
            TransactionObj => $args{'Transaction'},
        },
    );
    unless ( $status ) {
        $RT::Logger->error("Couldn't send 'Error to RT owner: public key'");
    }

    DeleteRecipientsFromHead(
        $args{'Entity'}->head,
        map $_->{'AddressObj'}->address, @bad_recipients
    );

    unless ( $args{'Entity'}->head->get('To')
          || $args{'Entity'}->head->get('Cc')
          || $args{'Entity'}->head->get('Bcc') )
    {
        $RT::Logger->debug("$msgid No recipients that have public key, not sending");
        return -1;
    }

    # redo without broken recipients
    %res = RT::Crypt->SignEncrypt( %args );
    return 0 if $res{'exit_code'};

    return 1;
}

=head3 DeleteRecipientsFromHead HEAD RECIPIENTS

Gets a head object and list of addresses.
Deletes addresses from To, Cc or Bcc fields.

=cut

sub DeleteRecipientsFromHead {
    my $head = shift;
    my %skip = map { lc $_ => 1 } @_;

    foreach my $field ( qw(To Cc Bcc) ) {
        $head->replace( $field => Encode::encode( "UTF-8",
            join ', ', map $_->format, grep !$skip{ lc $_->address },
                Email::Address->parse( Encode::decode( "UTF-8", $head->get( $field ) ) ) )
        );
    }
}

=head3 EncodeToMIME

Takes a hash with a String and a Charset. Returns the string encoded
according to RFC2047, using B (base64 based) encoding.

String must be a perl string, octets are returned.

If Charset is not provided then $EmailOutputEncoding config option
is used, or "latin-1" if that is not set.

=cut

sub EncodeToMIME {
    my %args = (
        String => undef,
        Charset  => undef,
        @_
    );
    my $value = $args{'String'};
    return $value unless $value; # 0 is perfect ascii
    my $charset  = $args{'Charset'} || RT->Config->Get('EmailOutputEncoding');
    my $encoding = 'B';

    # using RFC2047 notation, sec 2.
    # encoded-word = "=?" charset "?" encoding "?" encoded-text "?="

    # An 'encoded-word' may not be more than 75 characters long
    #
    # MIME encoding increases 4/3*(number of bytes), and always in multiples
    # of 4. Thus we have to find the best available value of bytes available
    # for each chunk.
    #
    # First we get the integer max which max*4/3 would fit on space.
    # Then we find the greater multiple of 3 lower or equal than $max.
    my $max = int(
        (   ( 75 - length( '=?' . $charset . '?' . $encoding . '?' . '?=' ) )
            * 3
        ) / 4
    );
    $max = int( $max / 3 ) * 3;

    chomp $value;

    if ( $max <= 0 ) {

        # gives an error...
        $RT::Logger->crit("Can't encode! Charset or encoding too big.");
        return ($value);
    }

    return ($value) if $value =~ /^(?:[\t\x20-\x7e]|\x0D*\x0A[ \t])+$/s;

    $value =~ s/\s+$//;

    my ( $tmp, @chunks ) = ( '', () );
    while ( length $value ) {
        my $char = substr( $value, 0, 1, '' );
        my $octets = Encode::encode( $charset, $char );
        if ( length($tmp) + length($octets) > $max ) {
            push @chunks, $tmp;
            $tmp = '';
        }
        $tmp .= $octets;
    }
    push @chunks, $tmp if length $tmp;

    # encode an join chuncks
    $value = join "\n ",
        map MIME::Words::encode_mimeword( $_, $encoding, $charset ),
        @chunks;
    return ($value);
}

sub GenMessageId {
    my %args = (
        Ticket      => undef,
        Scrip       => undef,
        ScripAction => undef,
        @_
    );
    my $org = RT->Config->Get('Organization');
    my $ticket_id = ( ref $args{'Ticket'}? $args{'Ticket'}->id : $args{'Ticket'} ) || 0;
    my $scrip_id = ( ref $args{'Scrip'}? $args{'Scrip'}->id : $args{'Scrip'} ) || 0;
    my $sent = ( ref $args{'ScripAction'}? $args{'ScripAction'}->{'_Message_ID'} : 0 ) || 0;

    return "<rt-". $RT::VERSION ."-". $$ ."-". CORE::time() ."-". int(rand(2000)) .'.'
        . $ticket_id ."-". $scrip_id ."-". $sent ."@". $org .">" ;
}

sub SetInReplyTo {
    my %args = (
        Message   => undef,
        InReplyTo => undef,
        Ticket    => undef,
        @_
    );
    return unless $args{'Message'} && $args{'InReplyTo'};

    my $get_header = sub {
        my @res;
        if ( $args{'InReplyTo'}->isa('MIME::Entity') ) {
            @res = map {Encode::decode("UTF-8", $_)} $args{'InReplyTo'}->head->get( shift );
        } else {
            @res = $args{'InReplyTo'}->GetHeader( shift ) || '';
        }
        return grep length, map { split /\s+/m, $_ } grep defined, @res;
    };

    my @id = $get_header->('Message-ID');
    #XXX: custom header should begin with X- otherwise is violation of the standard
    my @rtid = $get_header->('RT-Message-ID');
    my @references = $get_header->('References');
    unless ( @references ) {
        @references = $get_header->('In-Reply-To');
    }
    push @references, @id, @rtid;
    if ( $args{'Ticket'} ) {
        my $pseudo_ref = PseudoReference( $args{'Ticket'} );
        push @references, $pseudo_ref unless grep $_ eq $pseudo_ref, @references;
    }
    splice @references, 4, -6
        if @references > 10;

    my $mail = $args{'Message'};
    $mail->head->replace( 'In-Reply-To' => Encode::encode( "UTF-8", join ' ', @rtid? (@rtid) : (@id)) ) if @id || @rtid;
    $mail->head->replace( 'References' => Encode::encode( "UTF-8", join ' ', @references) );
}

sub PseudoReference {
    my $ticket = shift;
    return '<RT-Ticket-'. $ticket->id .'@'. RT->Config->Get('Organization') .'>';
}


sub AddSubjectTag {
    my $subject = shift;
    my $ticket  = shift;
    unless ( ref $ticket ) {
        my $tmp = RT::Ticket->new( RT->SystemUser );
        $tmp->Load( $ticket );
        $ticket = $tmp;
    }
    my $id = $ticket->id;
    my $queue_tag = $ticket->QueueObj->SubjectTag;

    my $tag_re = RT->Config->Get('EmailSubjectTagRegex');
    unless ( $tag_re ) {
        my $tag = $queue_tag || RT->Config->Get('rtname');
        $tag_re = qr/\Q$tag\E/;
    } elsif ( $queue_tag ) {
        $tag_re = qr/$tag_re|\Q$queue_tag\E/;
    }
    return $subject if $subject =~ /\[$tag_re\s+#$id\]/;

    $subject =~ s/(\r\n|\n|\s)/ /g;
    chomp $subject;
    return "[". ($queue_tag || RT->Config->Get('rtname')) ." #$id] $subject";
}

sub _RecordSendEmailFailure {
    my $ticket = shift;
    if ($ticket) {
        $ticket->_NewTransaction(
            Type => "SystemError",
            Data => "Sending the previous mail has failed.  Please contact your admin, they can find more details in the logs.", #loc
            ActivateScrips => 0,
        );
        return 1;
    }
    else {
        $RT::Logger->error( "Can't record send email failure as ticket is missing" );
        return;
    }
}

=head3 ConvertHTMLToText HTML

Takes HTML characters and converts it to plain text characters.
Appropriate for generating a plain text part from an HTML part of an
email.  Returns undef if conversion fails.

=cut

sub ConvertHTMLToText {
    return _HTMLFormatter()->(@_);
}

sub _HTMLFormatter {
    state $formatter;
    return $formatter if defined $formatter;

    my $wanted = RT->Config->Get("HTMLFormatter");

    my @order;
    if ($wanted) {
        @order = ($wanted, "core");
    } else {
        @order = ("w3m", "elinks", "links", "html2text", "lynx", "core");
    }
    # Always fall back to core, even if it is not listed
    for my $prog (@order) {
        if ($prog eq "core") {
            RT->Logger->info("Using internal Perl HTML -> text conversion");
            require HTML::FormatText::WithLinks::AndTables;
            $formatter = \&_HTMLFormatText;
        } else {
            unless (HTML::FormatExternal->require) {
                RT->Logger->warn("HTML::FormatExternal is not installed; falling back to internal perl formatter")
                    if $wanted;
                next;
            }

            my $path = $prog =~ s{(.*/)}{} ? $1 : undef;
            my $package = "HTML::FormatText::" . ucfirst($prog);
            unless ($package->require) {
                RT->Logger->warn("$prog is not a valid formatter provided by HTML::FormatExternal")
                    if $wanted;
                next;
            }

            if ($path) {
                local $ENV{PATH} = $path;
                local $ENV{HOME} = File::Spec->tmpdir();
                if (not defined $package->program_version) {
                    RT->Logger->warn("Could not find or run external '$prog' HTML formatter in $path$prog")
                        if $wanted;
                    next;
                }
            } else {
                local $ENV{PATH} = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
                    unless defined $ENV{PATH};
                local $ENV{HOME} = File::Spec->tmpdir();
                if (not defined $package->program_version) {
                    RT->Logger->warn("Could not find or run external '$prog' HTML formatter in \$PATH ($ENV{PATH}) -- you may need to install it or provide the full path")
                        if $wanted;
                    next;
                }
            }

            RT->Logger->info("Using $prog for HTML -> text conversion");
            $formatter = sub {
                my $html = shift;
                my $text = RT::Util::safe_run_child {
                    local $ENV{PATH} = $path || $ENV{PATH}
                        || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
                    local $ENV{HOME} = File::Spec->tmpdir();
                    $package->format_string(
                        Encode::encode( "UTF-8", $html ),
                        input_charset => "UTF-8",
                        output_charset => "UTF-8",
                        leftmargin => 0, rightmargin => 78
                    );
                };
                $text = Encode::decode( "UTF-8", $text );
                return $text;
            };
        }
        RT->Config->Set( HTMLFormatter => $prog );
        last;
    }
    return $formatter;
}

sub _HTMLFormatText {
    my $html = shift;

    my $text;
    eval {
        $text = HTML::FormatText::WithLinks::AndTables->convert(
            $html => {
                leftmargin      => 0,
                rightmargin     => 78,
                no_rowspacing   => 1,
                before_link     => '',
                after_link      => ' (%l)',
                footnote        => '',
                skip_linked_urls => 1,
                with_emphasis   => 0,
            }
        );
        $text //= '';
    };
    $RT::Logger->error("Failed to downgrade HTML to plain text: $@") if $@;
    return $text;
}


RT::Base->_ImportOverlays();

1;
