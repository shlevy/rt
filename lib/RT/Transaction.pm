# Copyright 1999 Jesse Vincent <jesse@fsck.com>
# Released under the terms of the GNU Public License
# $Id$ 
#
#
package RT::Transaction;
use RT::Record;
@ISA= qw(RT::Record);

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};
  bless ($self, $class);

  $self->{'table'} = "transactions";
  $self->_Init(@_);
  return ($self);
}


#take simple args and call MKIA::Database::Record to do the real work.
sub Create {
  my $self = shift;
  return($self->create(@_));
}

sub create {
  my $self = shift;
  
  my %args = ( id => undef,
	       TimeTaken => 0,
	       Ticket => '',

               Type => '',
	       Data => '',

	       Content => '',
	       @_
	     );
  #if we didn't specify a ticket, we need to bail
  return (0) if (! $args{'ticket'});

  #lets create our parent object
  my $id = $self->SUPER::Create(ticket => $args{'ticket'},
				effective_ticket  => $args{'ticket'},
				time_taken => $args{'TimeTaken'},
				date => time(),
				time_taken => $args{'time_taken'},
				type => $args{'type'},
				content => $args{'content'},
				data => $args{'data'}
				actor => $self->CurrentUser(),
			       );
  return ($id);
}


sub EffectiveTicket {
  my $self = shift;
  return($self->_set_and_return('effective_ticket'));
}

#Table specific data accessors/ modifiers
sub Type {
  my $self = shift;
  return($self->_set_and_return('type'));
}
sub Actor {
  my $self = shift;
  return($self->_set_and_return('actor'));
}

sub Ticket {
  my $self = shift;
  return($self->_set_and_return('ticket'));
}

#sub url {
#  my $self = shift;
#  return($self->_set_and_return('url'));
#}

sub Date {
  my $self = shift;
  return($self->_set_and_return('date'));
}

sub DateAsString {
  my $self = shift;
  return($self->_set_and_return('date'));
}

sub Data {
  my $self = shift;
  return($self->_set_and_return('data'));
}

sub Content {
  my $self=shift;
  return($self->_set_and_return('content'));
}

sub TimeTaken {
  my $self=shift;
  return($self->_set_and_return('time_taken'));
}

sub Description {
  my $self = shift;
  if ($self->Type eq 'create'){
    return("Request created by ".$self->Actor);
  }
  elsif ($self->Type eq 'correspond')    {
    return("Mail sent by ". $self->Actor);
  }
  
  elsif ($self->Type eq 'comments')  {
    return( "Comments added by ".$self->Actor);
  }
  
  elsif ($self->Type eq 'area')  {
    my $to = $self->{'data'};
    $to = 'none' if ! $to;
    return( "Area changed to $to by". $self->Actor);
  }
  
  elsif ($self->Type eq 'status'){
    if ($self->Data eq 'dead') {
      return ("Request killed by ". $self->Actor);
    }
    else {
      return( "Status changed to ".$self->Data." by ".$self->Actor);
    }
  }
  elsif ($self->Type eq 'queue_id'){
    return( "Queue changed to ".$self->Data." by ".$self->Actor);
  }
  elsif ($self->Type eq 'owner'){
    if ($self->Data eq $self->Actor){
      return( "Taken by ".$self->Actor);
    }
    elsif ($self->Data eq ''){
      return( "Untaken by ".$self->Actor);
    }
    
    else{
      return( "Owner changed to ".$self->Data." by ". $self->Actor);
    }
  }
  elsif ($self->Type eq 'requestors'){
    return( "User changed to ".$self->Data." by ".$self->Actor);
  }
  elsif ($self->Type eq 'priority') {
    return( "Priority changed to ".$self->Data." by ".$self->Actor);
      }    
  elsif ($self->Type eq 'final_priority') {
    return( "Final Priority changed to ".$self->Data." by ".$self->Actor);
      }
  elsif ($self->Type eq 'date_due') {  
    ($wday, $mon, $mday, $hour, $min, $sec, $TZ, $year)=&parse_time(".$self->Data.");
      $text_time = sprintf ("%s, %s %s %4d %.2d:%.2d:%.2d", $wday, $mon, $mday, $year,$hour,$min,$sec);
    return( "Date Due changed to $text_time by ".$self->Actor);
    }
  elsif ($self->Type eq 'subject') {
      return( "Subject changed to ".$self->Data." by ".$self->Actor);
      }
  elsif ($self->Type eq 'date_told') {
    return( "User notified by ".$self->Actor);
      }
  elsif ($self->Type eq 'effective_sn') {
    return( "Request $self->{'serial_num'} merged into ".$self->Data." by ".$self->Actor);
  }
  elsif ($self->Type eq 'subreqrsv') {
    return "Subrequest #".$self->Data." resolved by ".$self->Actor;
  }
  elsif ($self->Type eq 'link') {
    #TODO: make this fit with the rest of things.
    
    #my ($db, $fid, $type, $remote)=split(/\/, $self->{'data'});
    if ($type =~ /^dependency(-?)$/) {
      #$remote=(defined $remote) ? " at $remote" : "";
      if ($1 eq '-') {
	return ("Request \#$fid$remote made dependent on this request by ".$self->Actor);
      } else {
	return ("This request made dependent on request \#$fid$remote by ".$self->Actor);
      }
    } else {
      
      # Some kind of plugin system needed here.
      
      return ("$type linked to $fid at $remote by ".$self->Actor);
    }
  }
  else {
    return($self->Type . " modified. RT Should be more explicit about this!");
  }
  
    
}

1;
