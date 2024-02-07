if DEB_BUILD

bash_completion:
	cp ../bash_completion.d/znapzendzetup znapzend.bash-completion

service_files:
	cp ../init/znapzend.service znapzend.service

defaults:
	cp ../init/znapzend.default znapzend.default

all: defaults service_files bash_completion

endif
