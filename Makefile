up:
	rm -f eksctl.log .vars.sh
	time ./eksctl.sh 2>&1 | tee -a eksctl.log

down:
	rm -f clean.log
	time ./eksctl_clean.sh 2>&1 | tee -a clean.log

test1:
	bash -x test1.sh

clean:
	rm -f clean.log
	rm -f eksctl.log
	rm -f cluster.yaml
