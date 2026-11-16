/**
 * @author UCM ANDES Lab
 * $Author: abeltran2 $
 * $LastChangedDate: 2014-08-31 16:06:26 -0700 (Sun, 31 Aug 2014) $
 *
 */


#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"

module CommandHandlerP{
   provides interface CommandHandler;
   uses interface Receive;
   uses interface Pool<message_t>;
   uses interface Queue<message_t*>;
   uses interface Packet;
}

implementation{
    uint16_t readNetwork16(uint8_t *bytes){
        return ((uint16_t)bytes[0] << 8) | bytes[1];
    }

    // Dispatch queued simulator commands, including routing metric selection.
    task void processCommand(){
        if(! call Queue.empty()){
            CommandMsg *msg;
            uint8_t commandID;
            uint8_t* buff;
            message_t *raw_msg;
            void *payload;

            // Pop message out of queue.
            raw_msg = call Queue.dequeue();
            payload = call Packet.getPayload(raw_msg, sizeof(CommandMsg));

            // Check to see if the packet is valid.
            if(!payload){
                call Pool.put(raw_msg);
                post processCommand();
                return;
            }
            // Change it to our type.
            msg = (CommandMsg*) payload;

            dbg(COMMAND_CHANNEL, "A Command has been Issued.\n");
            buff = (uint8_t*) msg->payload;
            commandID = msg->id;

            //Find out which command was called and call related command
            switch(commandID){
            // A ping will have the destination of the packet as the first
            // value and the string in the remainder of the payload
            case CMD_PING:
                dbg(COMMAND_CHANNEL, "Command Type: Ping\n");
                signal CommandHandler.ping(buff[0], &buff[1]);
                break;

            case CMD_FLOOD_PING:
                dbg(COMMAND_CHANNEL, "Command Type: Flood Ping\n");
                signal CommandHandler.floodPing(buff[0], &buff[1]);
                break;

            case CMD_ROUTING_METRIC:
                dbg(COMMAND_CHANNEL, "Command Type: Routing Metric\n");
                signal CommandHandler.setRoutingMetric(buff[0]);
                break;

            case CMD_NEIGHBOR_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Neighbor Dump\n");
                signal CommandHandler.printNeighbors();
                break;

            case CMD_LINKSTATE_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Link State Dump\n");
                signal CommandHandler.printLinkState();
                break;

            case CMD_ROUTETABLE_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Route Table Dump\n");
                signal CommandHandler.printRouteTable();
                break;

            case CMD_TEST_CLIENT:
                dbg(COMMAND_CHANNEL, "Command Type: TCP test client\n");
                signal CommandHandler.setTestClient(
                    readNetwork16(buff), readNetwork16(&buff[2]),
                    buff[4], buff[5], readNetwork16(&buff[6]));
                break;

            case CMD_TEST_SERVER:
                dbg(COMMAND_CHANNEL, "Command Type: TCP test server\n");
                signal CommandHandler.setTestServer(readNetwork16(buff),
                                                    buff[2]);
                break;

            case CMD_CLIENT_CLOSE:
                dbg(COMMAND_CHANNEL, "Command Type: TCP client close\n");
                signal CommandHandler.closeTestClient(
                    readNetwork16(buff), readNetwork16(&buff[2]),
                    buff[4], buff[5]);
                break;

            default:
                dbg(COMMAND_CHANNEL, "CMD_ERROR: \"%d\" does not match any known commands.\n", msg->id);
                break;
            }
            call Pool.put(raw_msg);
        }

        if(! call Queue.empty()){
            post processCommand();
        }
    }
    // Queue incoming simulator commands for processCommand to handle safely.
    event message_t* Receive.receive(message_t* raw_msg, void* payload, uint8_t len){
        if (! call Pool.empty()){
            call Queue.enqueue(raw_msg);
            post processCommand();
            return call Pool.get();
        }
        return raw_msg;
    }
}
