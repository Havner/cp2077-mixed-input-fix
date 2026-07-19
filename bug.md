> Originally posted as
> [a post on r/cyberpunkgame](https://www.reddit.com/r/cyberpunkgame/comments/1obho7g/the_mixed_inputs_bugfreezecrash_cdpr_refuses_to/),
> where further discussion and other players' reports can be found. Kept here
> verbatim as the problem statement this plugin solves.

# TL;DR

Since version 2.11 Cyberpunk 2077 has a bug where using mixed controls will
inevitably freeze the game after 20m - 1h and then crash. The issue was reported
to CDPR, but they ignored it because according to them this is "unsupported
configuration".

If this sounds like your case, please read on.

# Symptoms

When I say "using mixed controls", it can be anything like:

* Steam Controller with buttons mapped as controller and touchpad and/or gyro to
  mouse
* PS4/5 controller with gyro mapped to mouse
* keyboard with analog buttons mapped as XBox sticks (e.g. Wooting 60he)
* XBox controller with right stick mapped as mouse
* SteamDeck with something (gyro, stick, touchpad) mapped as mouse
* simply playing with a controller in the left hand and mouse in the right hand
* and many more...

Basically anything that causes the button input hints (that show what you need
to press to achieve an action) to flicker between controller and K+M.

And when you do play like this depending on how much inputs you send to the game
and probably how many UI flickers happened the game freezes after 20m - 1h. The
more buttons you press and the more intensively you play the faster this
happens.

This basically freezes the screen with audio continuing to play and after 120
seconds the cyberpunk's watchdog crashes the game. This happens on Windows and
Linux (SteamDeck), on Steam and GOG version, on every possible PC configuration.

If this description matches your setup and you're experiencing similar crashes,
please check if switching to pure controller or pure K+M (they can still be
mapped on Steam Controller) fixes the issue. If so please let us know here and
consider reporting this to CDPR.

# Why it's important

Mixed controls are important for me and for others because it's basically the
best control scheme if you're using a controller. It gives you precise mouse
(with gyro, stick or a touchpad) and analog controls for movement and driving
vehicles.

Additionally I think it's important for accessibility. I've read reports on
early Cyberpunk versions of a person that had to use mixed controls cause of a
disability. There was a different bug back then that prevented them from doing
that. If that person would play Cyberpunk today they would not be able to as
well.

Even in my case I cannot play long with K+M because of carpal tunnel syndrome
induced pain and regular XBox controller with right stick is too slow and
imprecise for my liking. Mixed controls on Steam Controller is the only way for
me to properly enjoy the game for longer sessions.

# Investigation

Till 2.1 there was no issue. For some reason versions up to this one did not
switch the input hints back to K+M when emulated mouse was moved. There was no
hints flickering, no freeze, no crash.

In 2.11 CDPR changed this (probably to fix a bug people had with wrong input
hints being displayed sometimes) and this caused UI flickering on mixed controls
and it seems it's somehow related to the freeze (some UI notifications exceeding
some limit?).

I've tested this for dozens of hours (versions 2.11 - 2.3). I can play 6-8h
straight with Steam Controller mapped purely as K+M with no issues. The moment I
switch to mixed inputs I can freeze the game in 20 minutes. On 2.1 I can play
with mixed controls for hours without any issue. I've heavily re-tested both
behaviors recently on clean installations of 2.1 and 2.3 with zero mods and new
characters.

Also this is not Steam Input related. I have my own software that can remap
controls, map Steam Controller, etc and the bug still happens with Steam not
even running (using GOG version). This issue is purely in Cyberpunk.

# Reporting the issue

After investigation I've decided to go with the official way and report this to
CDPR support. After typical back and forth (with mods and savegames) when
they've stopped making me jump through hoops they basically shut me down with an
"unsupported configuration" excuse (even though they knew my exact configuration
since my very first email).

It boggles my mind how a company that has everything given on a golden platter
(the investigation, ways to reproduce) regarding a 100% reproducible bug/crash
doesn't want to fix it. Or at least try to reproduce it on their side.

There are tons of reports of the game freezing/crashing and most probably some
of them are caused by this with people not even aware this is the reason,
wondering what is wrong with their setup.

I wonder if they also consider SteamDeck as unsupported. They even gave it a
"verified" stamp on Steam and have a graphic setting just for it. And the issue
is also happening there (assuming you map gyro and/or stick to mouse).

Other people's reports of this issue I've found quite a few reports of the
exactly same issue over the net. Some of the original posters figured it out
themselves and some confirmed it in the comments after my discussion with them.

I'll link other people's reports in a comment below.

# Why am I writing about this

1. To raise awareness, if you're experiencing a freeze/crash, maybe this is the
   cause, maybe you can at least work around it.
2. (If you are experiencing this) to ask for your help in reporting this to
   CDPR, the more reports the better, maybe they will actually consider this as
   something important and worth fixing.
3. To actually express my disappointment in CDPR, I love their games, I love
   Cyberpunk, this is actually a game of my lifetime and I want to be able to
   play it now and for years to come. It's heartbreaking to me I cannot play it
   the way I most enjoy it and I'm most comfortable with (I've been playing like
   this since 1.4).
