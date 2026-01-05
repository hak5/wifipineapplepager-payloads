#!/bin/bash
# Title:      	Little Labyrinth
# Description:  Hak5 based text adventure
# Author:       Cribbit
# Version:      1.1
# Category:     Games
# Prop:         Andrew Petro - BashVenture And All the Hak5 team!!!

# variables
noob=0
cow=0
abs=0
free=0
pineapple=0
fox=1
damage=0
fight=0
toby=0
sunglasses=0
prescript=0

quack_line () {
    if [[ $2 -eq 1 ]]; then
        LOG ""
    fi
    LOG "$1"
}

quack_cmds () {
	quack_line "Buttons are: A, B, UP, DOWN, LEFT, RIGHT" 1
}

wait_input () {
	LOG "> "
	WAIT_FOR_INPUT
}

good_bye () {	
	quack_line "Good Bye" 1
	exit
}

dead () {
	quack_line "Your Dead :-(" 1
	quack_line "Could have been worst, you might have died of dysentery."
	quack_line "Please try again !!" 1
	good_bye
}

wall_desc () {
	case $(($RANDOM % 16 + 1)) in
		1 ) quack_line "Nope. Wall." 1 ;;
		2 ) quack_line "WALL EQUALS TRUE." 1 ;;
		3 ) quack_line "Wall face, face wall." 1 ;;
		4 ) quack_line "Somehow you think walls don't apply to you. They do." 1 ;;
		5 ) quack_line "You take a look at the decor. It's pretty nice." 1 ;;
		6 ) quack_line "Nothing but wall here." 1 ;;
		7 ) quack_line "You can't walk through walls" 1 ;;
		8 ) quack_line "You faceplant the wall. Idiot." 1 ;;
		9 ) quack_line "You were going to go that way, then you took a wall to the face." 1 ;;
		10 ) quack_line "Not much over here." 1 ;;
		11 ) quack_line "There's a curtain - but no window behind it. How odd." 1 ;;
		12 ) quack_line "Seriously? Though the wall? Sorry, No." 1 ;;
		13 ) quack_line "Right, let me explain this whole 'wall' thing to you..." 1 ;;
		14 ) quack_line "You attempt to walk through the wall. You fail." 1 ;;
		15 ) quack_line "I'd tell you a joke about a twenty foot wall, but you'd never get over it." 1 ;;
		16 ) quack_line "This wall has wires hanging out of it. It may be a threat!" 1 ;;
	esac
}

ascii_art () {
	#quack_line " )  o _)_ _)_ )  _     )   _ ( _        _ o  _  _)_ ( _ " 1
	#quack_line "(__ ( (_  (_ (  )_)   (__ (_( )_) (_(  )  ( ) ) (_   ) )"
	#quack_line "               (_                   _)                  "
	quack_line "Little Labyrinth"
}


room_start () {
	ascii_art 
	quack_line "Will you be able to escape!!!"
	quack_line "Commands :" 1
	quack_line "UP = north"
	quack_line "RIGHT = east"
	quack_line "DOWN = south"
	quack_line "LEFT = west"
	quack_line "A = interact"
	quack_line "B = quit"
	quack_line "Upon awakening, you find your self in a room, you do not recognise." 1
	quack_line "The room is dark but you can see a door to the north of you."
	quack_line "You never know you might find a cake."

	while true; do
		command=$( wait_input )
		case $command in
			UP ) room1 ;;
			DOWN ) wall_desc ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}


room1 () {
	# https://www.youtube.com/watch?v=vsJn6Z34B8s
	# 0402
	# https://www.youtube.com/watch?v=teHRnEE0y4g
	quack_line "The room is well lit with a small table." 1
	quack_line "There is something on it!"
	quack_line "The exits are north, east and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room4 ;;
			DOWN ) quack_line "The door is locked" 1 ;;
			LEFT ) room3 ;;
			RIGHT ) room2 ;;
			A )
				if [[ $noob -eq 0 ]]; then
					quack_line "Oh it's NOOB LUBE!!" 1
					quack_line "You apply it liberally."
					noob=1
				else
					quack_line "You have use the whole tube." 1
				fi ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room2 () {
	quack_line "You entered a hallway!" 1
	quack_line "The exits are north, south and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room6 ;;
			DOWN ) room7 ;;
			LEFT ) room1 ;;
			RIGHT ) quack_line "There is something scratch on the wall" 1
				quack_line "EEF5204D6A" ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room3 () {
	# https://www.youtube.com/watch?v=gb6YAhTnMX8
	quack_line "The room has a high ceiling held up by four large pillars" 1
	quack_line "The exits are north and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room5 ;;
			DOWN ) wall_desc ;;
			LEFT ) quack_line "There is an advert telling you the benefits of the freeze pop diet." 1 ;;
			RIGHT ) room1 ;;
			A )
				quack_line "There is nothing in this room (apart form something on the west wall)" 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room4 () {
	quack_line "You find yourself in a cosy room, there is a cat sitting in front of a large fireplace." 1
	quack_line "The exits are north and south." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room10 ;;
			DOWN ) room1 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "You stroke the cat, it purrs gently." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room5 () {
	quack_line "You're in a large room." 1
	quack_line "Hanging from the ceiling is a huge chandelier." 
	quack_line "It's soo shiny." 
	quack_line "Well, it's not for you." 1 
	quack_line "You're just looking at a text editor." 
	quack_line "You'd have to turn your display brightness up to max." 
	quack_line "And it still wouldn't be as bright and shiny as this." 
	quack_line "It's so bright you can't see the exits." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) 
				if [[ $sunglasses -eq 0 ]]; then
					quack_line "It's so bright!!" 1
					quack_line "You can't find the door!!" 
				else
					room14
				fi ;;
			DOWN ) room3 ;;
			LEFT ) wall_desc;;
			RIGHT ) wall_desc ;;
			A )
				if [[ $sunglasses -eq 0 ]]; then 
					quack_line "You search your pockets for sunglasses." 1 
					quack_line "You don't have any."
				else
					quack_line "You look through the sunglasses." 1
					quack_line "And see a door to the north."
				fi ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room6 () {
	quack_line "It looks like a bar!!!" 1
	quack_line "The exits are north and south." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room16 ;;
			DOWN ) room2 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "You drink all the booze, but instead of hacking all the things." 1
				quack_line "You do a barrel roll." ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room7 () {
	quack_line "This must be the boiler room pipes everywhere." 1
	quack_line "The exits are north and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room2 ;;
			DOWN ) wall_desc ;;
			LEFT ) wall_desc ;;
			RIGHT ) room17 ;;
			A )
				quack_line "Pipe all the things." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room8 () {
	# 0303
	# https://www.youtube.com/watch?v=qRTruDjAeaI
	# https://www.youtube.com/watch?v=-_ISnUhs1CE
	quack_line "Wow, lots of arcade machines." 1
	quack_line "What is this 1984!"
	quack_line "The exits are south and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room27 ;;
			LEFT ) room21 ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "You play on the machines for a bit" 1 
				quack_line "Then you notice a leaflet."
				quack_line "Feed up of playing by yourself? Rent a player 2 with player2rentals.com" ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room9 () {
	# https://www.youtube.com/watch?v=RfzKlge4los
	quack_line "It's a store room. It's full of old MicroShaft products" 1
	quack_line "The exits are west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) wall_desc ;;
			LEFT ) room27 ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "Oh, it the mini. I bet it's BLT drive went AWOL" 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room10 () {
	# https://www.youtube.com/watch?v=zUYq5FSv5Rs
	quack_line "You enter a hallway and find a packet of" 1
	quack_line "Conficker doodles!"
	quack_line "The exit is south." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room4 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "You look at the use by date 2009." 1
				quack_line "You put them back down." ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room11 () {
	# 0310
	# https://www.youtube.com/watch?v=umRFauwT7jI
	quack_line "You enter what looks like a living room." 1
	quack_line "That sofa looks comfy."
	quack_line "The exits are north and south." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room13 ;;
			DOWN ) room21 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "You sit on the sofa." 1
				quack_line "There is something next to you." 
				quack_line "It's a Fail Bus Ticket." 
				quack_line "Fail Bus going nowhere at the speed of fail." ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room12 () {
	# https://www.youtube.com/watch?v=Qu8UHJdE8Gk
	quack_line "There is someone standing in the corner, they look upset" 1
	quack_line "The exits are north." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room18 ;;
			DOWN ) wall_desc ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				if [[ $prescript -eq 0 ]]; then
					quack_line "They say their name is TobyToby and they are suffering from Borked Bits." 1
					toby=1
				elif [[ $prescript -eq 1 ]]; then
					if [[ $toby -eq 0 ]]; then
						quack_line "Their name is TobyToby and they are suffering from Borked Bits.." 1	
					fi
					quack_line "You give TobyToby the prescription." 1 
					quack_line "In return he gives you some sunglasses." 1
					sunglasses=1
					prescript=2	
				else	
					quack_line "TobyToby is feeling better." 1	
				fi
				;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room13 () {
	quack_line "There is a long haired man sitting at a table" 1
	quack_line "The exits are north and south." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room15 ;;
			DOWN ) room11 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				if [[ $cow -eq 0 ]]; then
					quack_line "It's dangerous to go alone, take this!" 1
					quack_line "A small plush COW!!!"
					cow=1
				else
					quack_line "Hey! Listen! I gave you the cow." 1
				fi ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room14 () {
	# https://www.youtube.com/watch?v=zno4lkg-Sfw
	quack_line "Why, that's the second biggest network monkey" 1
	quack_line "I've ever seen" 
	quack_line "The exits are south and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			n|RIGHT ) wall_desc ;;
			DOWN ) room5 ;;
			LEFT ) room15 ;;
			A )
				quack_line "You have a cuddle with the network monkey, and feel better about your predicament" 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room15 () {
	# https://www.youtube.com/watch?v=Z5L3f1qb1VA
	quack_line "Room 101." 1
	quack_line "The exits are south and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room13 ;;
			LEFT ) quack_line "Scratch and Sniff packet stickers, nice GBMP" 1 ;;
			RIGHT ) room14 ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room16 () {
	quack_line "You're in that place where i put that thing that time." 1
	quack_line "The exits are south and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room6 ;;
			LEFT ) wall_desc ;;
			RIGHT ) room20 ;;
			A )
				quack_line "You find a floppy disk." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room17 () {	
	# 1803 - 1805
	# https://www.youtube.com/watch?v=xLlwlVaRuik
	# https://www.youtube.com/watch?v=Vsc-SA0g5Fo
	# https://www.youtube.com/watch?v=WoX6oQwyb3c
	quack_line "Not another hallway." 1
	quack_line "It's like I'm running out of ideas for room descriptions."
	quack_line "But there is something or someone in here."
	quack_line "The exits are south and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room33 ;;
			LEFT ) room7 ;;
			RIGHT ) wall_desc ;;
			A )
				if [[ $prescript -eq 0 ]]; then
					quack_line "You find the best co-host Greg Dinosaur just hanging out." 1 
					quack_line "He give you a prescription for a terabyte raid array." 1
					prescript=1
				else	
					quack_line "Greg Dinosaur is still just hanging out." 1	
				fi
				;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room18 () {
	quack_line "I think you ought to know I'm feeling very depressed." 1
	quack_line "Brain the size of a planet."
	quack_line "And all you've got me doing is QUACKing out new room descriptions." 
	quack_line "Who ever heard of a croc quacking?" 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room20 ;;
			DOWN ) room12 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "I could calculate your chance of survival, but you won't like it." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room19 () {
	# just watch series 1
	quack_line "As you walk into the room, the door locks behind you!" 1
	sleep 5
	quack_line "You start to see a faint red glow, then you hear:" 
	sleep 5
	quack_line "Do not attempt to adjust your text editor" 
	quack_line "It is I the most awesome and omnipotent"
	sleep 5
	quack_line "EVIL SERVER" 1 
	sleep 5
	quack_line "Together me and my script kiddies will take over hak.5 once and for all!!!" 1
	
	while true; do
		command=$( wait_input )
		case $command in
			A )	 
				quack_line "EVIL SERVER goes from the attack!" 1 
				((fight=fight+1))			
				case $fight in
					1 ) 
						if [[ $noob -eq 0 ]]; then
							quack_line "You didn't apply the noob lube you take a hit."
							((damage=damage+1))
						else	
							quack_line "The noob lube protected you from the hit."	
						fi 
						;;
					2 ) 
						if [[ $abs -eq 0 ]]; then
							quack_line "You didn't find the special powers you take a hit."
							((damage=damage+1))
						else	
							quack_line "Your newly acquired abs protected you from the hit."	
						fi 
						;;
					4 ) 
						if [[ $free -eq 0 ]]; then
							quack_line "Wait what you didn't get you free copy of nmap."
							quack_line "Sorry, you take a hit."
							((damage=damage+1))
						else	
							quack_line "The copy of nmap protected you from the hit." 	
						fi 
						;;
					3 ) 
						if [[ $cow -eq 0 ]]; then
							quack_line "What you didn't get the cow!" 
							quack_line "What's wrong with you?" 
							quack_line "You take a hit." 
							((damage=damage+1))
						else	
							quack_line "The Cow protected you from the hit." 	
						fi 
						;;
					* )
						if [[ $damage -gt 2 ]]; then
							quack_line "You've taken to much damage!!!" 
							dead
						else
							quack_line "You walk over, unplug him and leave through the door." 1	
							sleep 5
							quack_line "That was a bit anticlimatic." 1	
							quack_line "Thank you for playing!" 
							sleep 5
							ascii_art 	
							good_bye
						fi 
						;;
				esac 
				;;	
			* ) quack_line "You can't run away now !!!" 1 
			;;
		esac
	done
}

room20 () {
	quack_line "There is something moving a round in here" 1
	quack_line "The exits are south and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room18 ;;
			LEFT ) room16 ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "It's a glider it likes to mubix mubix" 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room21 () {
	# https://www.youtube.com/watch?v=R-_1729sU8k
	quack_line "It's a kitchen!!!" 1
	quack_line "Maybe there is something to eat" 
	quack_line "The exits are north and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room11 ;;
			DOWN ) wall_desc ;;
			LEFT ) wall_desc ;;
			RIGHT ) room8 ;;
			A )
				quack_line "You have a nice big bowl of Hax0rFlakes" 1 
				quack_line "Wow a free copy of nmap"				
				free=1;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room22 () {
	# 411
	# https://www.youtube.com/watch?v=HGdZRx-39mM
	# 403
	# https://www.youtube.com/watch?v=lkLV7xGIso0
	quack_line "This room is full of flamingos" 1
	quack_line "The exits are north." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room33 ;;
			s|w|RIGHT ) quack_line "FLAMINGOS, if only you had an action figure with kung-fu grip" 1 ;;
			A )
				quack_line "Strange this flamingo is made of plastic, with a label on it." 1
				quack_line "Property of Paul" ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room23 () {
	quack_line "There is someone sitting in a Miata" 1
	quack_line "I wonder how they got it to fit in such a small room." 
	quack_line "The exits are north and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room26 ;;
			DOWN ) wall_desc ;;
			LEFT ) wall_desc ;;
			RIGHT ) room32 ;;
			A )
				quack_line "You tap on the window." 1
				quack_line "They show you their multi pass." ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room24 () {
	quack_line "There is a fox with a dapper moustache wearing sunglasses." 1
	quack_line "They seem to be holding some sort of fruit."
	
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) 
				if [[ $pineapple -eq 0 ]]; then
					quack_line "Did that wall just wobble?" 1
				else
					room30 
				fi ;;
			LEFT ) room32 ;;
			RIGHT ) quack_line "A poster, i heart pizza" 1 ;;
			A )
				if [[ $pineapple -eq 0 ]]; then
					quack_line "The fruit it's a pineapple with a small button." 1
					quack_line "You push the button for 4 seconds"
					sleep 1
					quack_line "1"
					sleep 1
					quack_line "2"
					sleep 1
					quack_line "3"
					sleep 1
					quack_line "4"
					quack_line "Did anything happen?"
					pineapple=1
				else
					case $fox in
							1 ) quack_line "Stop pressing the button you are going to make the fox angry." 1 ;;
							2 ) quack_line "The fox raises an eye brow." 1 ;;
							3 ) quack_line "The fox is starting to snarl." 1 ;;
							4 ) quack_line "They are reaching for their ban hammer." 1 ;;
							* )
								quack_line "They hit you on your head." 1
								dead
								;;
					esac				
					((fox=fox+1))
				fi ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room25 () {
	# 2316 
	# You have to watch Sarah impression of Snubs
	# https://www.youtube.com/watch?v=3WfjlvfOrcY
	quack_line "There is a large tree in front of you." 1
	quack_line "With a squirrel on one of the brunches." 
	quack_line "The exits are north and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room32 ;;
			DOWN ) wall_desc ;;
			LEFT ) room29 ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "The squirrel says his name is Brian." 1
				quack_line "That strange, he seems to be stuffed with an old duster." ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room26 () {
	quack_line "There is a large machine with a button on it." 1
	quack_line "The exits are south and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room23 ;;
			LEFT ) wall_desc ;;
			RIGHT ) room27 ;;
			A )
				quack_line "The machine whirls and gurgles, then a cup pops out." 1
				quack_line "Yum it's a slushy, very refreshing." ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room27 () {
	quack_line "IT'S A ROOM, OK." 1
	quack_line "You don't like the description." 
	quack_line "Make a pull request."
	quack_line "The exits are north, east and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room8 ;;
			DOWN ) wall_desc ;;
			LEFT ) room26 ;;
			RIGHT ) room9 ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room28 () {
	quack_line "You're in a small room with two fence panels." 1
	quack_line "The exits are north, east and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room31 ;;
			DOWN ) wall_desc ;;
			LEFT ) room30 ;;
			RIGHT ) room19 ;;
			A )
				quack_line "You note that both fence panels are coved in" 1
				quack_line "STICKERS!!!" 
				;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room29 () {
	quack_line "There must of been some sort of Glytch." 1
	quack_line "You're back in the room you started in." 1
	quack_line "The room is still dark but you can see the door to the north of you."
	quack_line "But hey at least you recognise the room."

	while true; do
		command=$( wait_input )
		case $command in
			UP ) room1 ;;
			DOWN ) wall_desc ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room30 () {
	# https://www.youtube.com/watch?v=oIeKnB_5u2U
	quack_line "This room seem to be made of fake bricks." 1
	quack_line "The exits are north and east." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room24 ;;
			DOWN ) quack_line "How weird there seem to be a framed motherboard hanging on this wall." 1 ;;
			LEFT ) wall_desc ;;
			RIGHT ) room28 ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room31 () {
	# https://www.youtube.com/watch?v=6HWcgaRs9CM
	quack_line "There is a girl she says she can give special powers." 1
	quack_line "The exits are south." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room28 ;;
			LEFT ) wall_desc ;;
			RIGHT ) wall_desc ;;
			A )
				if [[ $abs -eq 0 ]]; then
					quack_line "She takes out a marker and draws abs on you." 1
					abs=1
				else
					quack_line "what more do you want." 1
				fi ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done

}

room32 () {
	# Rene Magritte - The Treachery of Images
	quack_line "ce n'est pas une chambre." 1
	quack_line "This is not a room nor a pipe." 
	quack_line "The exits are south, east and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) wall_desc ;;
			DOWN ) room25 ;;
			LEFT ) room23 ;;
			RIGHT ) room24 ;;
			A )
				quack_line "There is nothing in this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room33 () {
	# 2601
	# https://www.youtube.com/watch?v=daLhn8lIbGo
	quack_line "The room you have entered is covered in some sort of drape." 1
	quack_line "The exits are north, south and west." 1
	while true; do
		command=$( wait_input )
		case $command in
			UP ) room17 ;;
			DOWN ) room22 ;;
			LEFT ) room29 ;;
			RIGHT ) quack_line "There is something written on the wall." 1
				quack_line "Short'a fuse, big'a boom!" ;;
			A )
				quack_line "There is nothing to do this room." 1 ;;
			B )
				good_bye
				;;
			* ) quack_cmds ;;
		esac
	done
}

room_start