#
# Copyright KOOMPI Co., LTD.
# Copyright 2016 The PIONUX OS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
NAME=pionux
VERSION=0.1
PKG_VERSION=1
ARCH=all
PKG=$(NAME)_$(VERSION)-$(PKG_VERSION)_$(ARCH).deb

pkg:
	fakeroot dpkg-deb --build debpkg/
	mv debpkg.deb $(PKG)

lint: pkg
	lintian $(PKG)

clean:
	-rm $(PKG)
