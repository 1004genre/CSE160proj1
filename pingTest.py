# 1. Create a 2-node topology
mkdir -p topo && echo -e "2\n1 2 -50.0\n2 1 -50.0" > topo/test.topo

# 2. Update pingTest to use the small layout
cat << 'EOF' > pingTest.py
from TestSim import TestSim

def main():
    s = TestSim()
    
    # Use the 2-node topology for a lightning fast test
    s.loadTopo("test.topo")        
    s.loadNoise("no_noise.txt")     
    s.bootAll()
    
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    
    # Run simple 1-second ticks
    s.runForSeconds(1)
    s.ping(1, 2, "Quick Test")
    s.runForSeconds(1)

if __name__ == '__main__':
    main()
EOF
